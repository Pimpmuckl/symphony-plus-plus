defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, SoloTools}
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.{Node, SliceLink}
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

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
  @local_operator_tools ["add_work_request_comment", "record_work_request_operator_decision"]
  @local_operator_text_max_length Comment.max_body_length()
  @local_operator_provenance_max_length 512
  @blocker_closeout_decisions ["resolved", "still_active"]
  @local_assignment_claim_tool "claim_local_assignment"
  @local_architect_assignment_claim_tool "claim_local_architect_assignment"
  @session_claim_tools [@local_assignment_claim_tool, @local_architect_assignment_claim_tool]
  @local_assignment_claim_hidden_worker_arguments ["repo", "base_branch", "work_request_id", "branch", "worktree_path", "caller_id"]
  @session_scoped_worker_tools [
    "update_task_plan",
    "append_finding",
    "append_progress",
    "set_status",
    "report_blocker",
    "resolve_blocker",
    "add_comment",
    "list_comments",
    "resolve_comment",
    "create_guidance_request",
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
    "set_status",
    "report_blocker",
    "resolve_blocker",
    "add_comment",
    "list_comments",
    "resolve_comment",
    "create_guidance_request",
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
    "cleanup_work_request_planned_slice_runtime",
    "record_planned_slice_delivery",
    "revoke_planned_slice_worker_key",
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
    "plan_slice",
    "upsert_plan_node",
    "move_plan_node",
    "set_plan_node_completion",
    "move_slice_to_plan_node",
    "approve_slice",
    "skip_slice",
    "finish_slicing",
    "dispatch_slice",
    "prepare_work_package_worktree",
    "cleanup_work_package_worktree",
    "read_child_status",
    "approve_scope_expansion",
    "read_phase_board",
    "approve_child_ready_state",
    "merge_child_into_phase"
  ]
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
    "plan_slice",
    "upsert_plan_node",
    "move_plan_node",
    "set_plan_node_completion",
    "move_slice_to_plan_node",
    "approve_slice",
    "skip_slice",
    "finish_slicing",
    "dispatch_slice"
  ]
  @current_work_request_write_tools [
    "plan_slice",
    "upsert_plan_node",
    "move_plan_node",
    "set_plan_node_completion",
    "move_slice_to_plan_node",
    "approve_slice",
    "skip_slice",
    "finish_slicing"
  ]
  @current_work_request_tools @current_work_request_write_tools ++
                                [
                                  "read_delivery_board",
                                  "reconcile_work_request",
                                  "cleanup_work_request_planned_slice_runtime",
                                  "record_planned_slice_delivery",
                                  "revoke_planned_slice_worker_key",
                                  "dispatch_slice"
                                ]
  @delivery_policy_tools [
    "reconcile_work_request",
    "cleanup_work_request_planned_slice_runtime",
    "record_planned_slice_delivery",
    "revoke_planned_slice_worker_key"
  ]
  @work_request_product_tree_views ["nodes_only", "nodes_with_slice_refs", "nodes_with_slices"]
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
  def contract_trusted_local_http_extra_tools, do: @bootstrap_tools ++ ["add_work_request_comment", "list_comments", "record_work_request_operator_decision"]

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

  @spec work_request_policy_tools() :: [tool_name()]
  def work_request_policy_tools, do: @work_request_policy_tools

  @spec delivery_policy_tools() :: [tool_name()]
  def delivery_policy_tools, do: @delivery_policy_tools

  @spec work_request_product_tree_views() :: [String.t()]
  def work_request_product_tree_views, do: @work_request_product_tree_views

  defp health_tool_spec do
    %{
      "name" => @health_tool,
      "title" => "Symphony++ health",
      "description" => "Returns server version, ledger reachability, and safe ledger identity without exposing package data.",
      "inputSchema" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{}
      }
    }
  end

  defp worker_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => "Symphony++ worker tool #{name}.",
      "inputSchema" => worker_tool_input_schema(name)
    }
  end

  defp unbound_worker_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => "Symphony++ worker tool #{name}.",
      "inputSchema" => unbound_worker_tool_input_schema(name)
    }
  end

  defp assignment_release_tool_spec do
    %{
      "name" => @assignment_release_tool,
      "title" => @assignment_release_tool,
      "description" => "Release only the current MCP session assignment binding and its matching current claim lease when available, without exposing secrets.",
      "inputSchema" => assignment_release_tool_input_schema()
    }
  end

  defp solo_tool_spec(name) do
    SoloTools.tool_spec(name)
  end

  defp bootstrap_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => bootstrap_tool_description(name),
      "inputSchema" => bootstrap_tool_input_schema(name)
    }
  end

  defp local_architect_assignment_claim_tool_spec do
    %{
      "name" => @local_architect_assignment_claim_tool,
      "title" => @local_architect_assignment_claim_tool,
      "description" => local_architect_assignment_claim_tool_description(),
      "inputSchema" => local_architect_assignment_claim_tool_input_schema()
    }
  end

  defp local_operator_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => local_operator_tool_description(name),
      "inputSchema" => local_operator_tool_input_schema(name)
    }
  end

  defp bootstrap_tool_description("create_work_request") do
    "Create a local Symphony++ WorkRequest with creator provenance and return a redacted architect handoff."
  end

  defp local_architect_assignment_claim_tool_description do
    "Claim or reconnect a ledger-backed local WorkRequest architect assignment without private handoff files."
  end

  defp local_operator_tool_description("add_work_request_comment") do
    "Append a redacted local-operator comment to a WorkRequest by id. Requires an unbound trusted local HTTP MCP session with an explicit state key and a file-backed local ledger; grants no dispatch or lifecycle authority."
  end

  defp local_operator_tool_description("record_work_request_operator_decision") do
    "Record a redacted local-operator decision on a WorkRequest by id. Requires an unbound trusted local HTTP MCP session with an explicit state key and a file-backed local ledger; does not require ownership of that WorkRequest."
  end

  defp architect_tool_spec(name) do
    %{
      "name" => name,
      "title" => name,
      "description" => architect_tool_description(name),
      "inputSchema" => architect_tool_input_schema(name)
    }
  end

  defp architect_tool_description("read_child_status"), do: "Read the architect grant's scoped child work-package status without Phase 7 delegation."
  defp architect_tool_description("create_child_work_package"), do: "Create a phase-child work package inside the architect grant's current phase."
  defp architect_tool_description("mint_child_worker_key"), do: "Mint a narrower worker grant for a phase-child work package in the architect grant's current phase."
  defp architect_tool_description("revoke_child_worker_key"), do: "Revoke one live child-worker grant for a same-phase child package in the architect grant's current phase."
  defp architect_tool_description("list_work_requests"), do: "List WorkRequests scoped to the architect grant's repo and base branch."
  defp architect_tool_description("read_work_request"), do: "Read a scoped WorkRequest with clarification questions, decisions, visible planned slices, and status summaries."
  defp architect_tool_description("read_plan"), do: "Read the scoped WorkRequest V3 product-tree projection, with optional slice refs or full visible slice payloads."
  defp architect_tool_description("add_comment"), do: "Add a policy-scoped comment to a claimed WorkRequest descendant package surface, or a narrow external comment to a visible WorkRequest."
  defp architect_tool_description("list_comments"), do: "List comments attached to a scoped WorkRequest, planned slice, or linked WorkPackage."
  defp architect_tool_description("resolve_comment"), do: "Resolve a policy-scoped comment attached to a claimed WorkRequest descendant package surface."
  defp architect_tool_description("resolve_blocker"), do: "Resolve a blocker event for a policy-scoped descendant WorkPackage."
  defp architect_tool_description("read_delivery_board"), do: "Read the scoped WorkRequest delivery-board projection for visible planned-slice closeout without broad package visibility."
  defp architect_tool_description("reconcile_work_request"), do: "Dry-run or apply deterministic WorkRequest delivery closeout repairs from structured PR/GitHub evidence."

  defp architect_tool_description("record_planned_slice_delivery") do
    "Record an idempotent planned-slice delivery closeout. Required evidence depends on outcome: pr_merged needs PR evidence, completed_no_pr needs direct evidence, superseded needs successor and reason, and abandoned needs rationale. Use abandoned for cleaned no-code failed dispatches that never reached implementation. If the linked WorkPackage has active blockers, answer blocker_closeout to say whether those blockers are resolved or intentionally still active."
  end

  defp architect_tool_description(tool) when tool in ["cleanup_work_request_planned_slice_runtime", "revoke_planned_slice_worker_key"],
    do: delivery_runtime_tool_description(tool)

  defp architect_tool_description("list_guidance_requests"), do: "List package-scoped guidance requests visible to the architect grant's phase, repo, and base branch."
  defp architect_tool_description("read_guidance_request"), do: "Read one package-scoped guidance request visible to the architect grant."
  defp architect_tool_description("answer_guidance_request"), do: "Answer an open package-scoped guidance request."
  defp architect_tool_description("escalate_guidance_request"), do: "Escalate an open guidance request to human_info_needed and project it as an active package blocker."
  defp architect_tool_description("set_work_request_status"), do: "Move a scoped WorkRequest between valid statuses with optimistic current-status checking."
  defp architect_tool_description("ask_question"), do: "Add a clarification question to a scoped WorkRequest."
  defp architect_tool_description("answer_question"), do: "Answer an open clarification question that belongs to a scoped WorkRequest."
  defp architect_tool_description("answer_question_and_record_decision"), do: "Answer an open clarification question and atomically record the resulting WorkRequest decision."
  defp architect_tool_description("close_question"), do: "Close an open clarification question that belongs to a scoped WorkRequest without recording an answer."

  defp architect_tool_description("record_decision"),
    do: "Record a durable decision log entry on a scoped WorkRequest. source_type must be one of: #{Enum.join(DecisionLogEntry.source_types(), ", ")}."

  defp architect_tool_description("plan_slice"),
    do: "Add a slice; standard_pr is ordinary PR work, while mcp is MCP server, protocol, tool, or plugin work."

  defp architect_tool_description("upsert_plan_node") do
    "Create or edit V3 product plan node content inside the claimed current WorkRequest. Do not create a plan node solely to wrap one slice. Leave simple slices direct unless the node groups multiple units or records a real product boundary."
  end

  defp architect_tool_description("move_plan_node") do
    "Reparent or reorder a V3 product plan node inside the claimed current WorkRequest."
  end

  defp architect_tool_description("set_plan_node_completion") do
    "Set a V3 product plan node completion mark inside the claimed current WorkRequest. If setting completion_mark to done or deferred and descendant blockers are active, answer blocker_closeout before completing the node."
  end

  defp architect_tool_description("move_slice_to_plan_node") do
    "Move a planned slice under a V3 product plan node in the claimed current WorkRequest, or unlink it back to the WorkRequest's direct slice list."
  end

  defp architect_tool_description("approve_slice") do
    "Approve a planned slice that belongs to the claimed current WorkRequest."
  end

  defp architect_tool_description("skip_slice") do
    "Skip a planned slice that belongs to the claimed current WorkRequest."
  end

  defp architect_tool_description("finish_slicing") do
    "Mark the claimed current WorkRequest sliced using the existing approved-slice requirement."
  end

  defp architect_tool_description("dispatch_slice") do
    "Dispatch one approved planned slice into a WorkPackage and redacted ledger-backed worker claim bootstrap."
  end

  defp architect_tool_description("prepare_work_package_worktree") do
    "Prepare a scoped WorkPackage git worktree and record only its worktree_path."
  end

  defp architect_tool_description("cleanup_work_package_worktree") do
    "Clean up a scoped WorkPackage git worktree after validating the recorded path and dirty state."
  end

  defp architect_tool_description("approve_scope_expansion"), do: "Approve additional allowed file globs for this scoped work package."
  defp architect_tool_description("read_phase_board"), do: "Read the architect grant's scoped phase board."
  defp architect_tool_description("approve_child_ready_state"), do: "Approve a ready phase-child package for merge into the architect's phase."
  defp architect_tool_description("merge_child_into_phase"), do: "Record a local phase merge artifact and mark a phase child merged into the architect's phase."

  @spec solo_tool_input_schema(tool_name()) :: input_schema()
  def solo_tool_input_schema(name), do: SoloTools.input_schema(name)

  @spec bootstrap_tool_input_schema(tool_name()) :: input_schema()
  def bootstrap_tool_input_schema("create_work_request") do
    schema(
      %{
        "repo" => string_schema(),
        "base_branch" => string_schema(),
        "title" => string_schema(),
        "description" => markdown_string_schema("WorkRequest human-facing description in Markdown."),
        "human_description" => markdown_string_schema("Deprecated alias for description; human-facing Markdown."),
        "request_kind" => string_enum_schema(WorkRequest.work_types()),
        "workflow_mode" => string_enum_schema(WorkRequest.dispatch_shapes()),
        "repo_scopes" => %{
          "type" => "array",
          "items" => %{"type" => "object", "additionalProperties" => false, "properties" => %{"repo" => string_schema(), "base_branch" => string_schema()}, "required" => ["repo"]}
        },
        "constraints" => object_schema(),
        "status" => string_enum_schema(WorkRequest.statuses()),
        "claimed_by" => string_schema(),
        "creator_kind" => string_enum_schema(WorkRequest.creator_kinds()),
        "created_by_kind" => string_enum_schema(WorkRequest.creator_kinds()),
        "creator_name" => string_schema(),
        "created_by_name" => string_schema(),
        "created_via" => string_schema()
      },
      ["repo", "base_branch", "title", "request_kind"]
    )
    |> always_validate(%{"anyOf" => [%{"required" => ["description"]}, %{"required" => ["human_description"]}]})
  end

  @spec local_operator_tool_input_schema(tool_name()) :: input_schema()
  def local_operator_tool_input_schema("add_work_request_comment") do
    schema(
      %{
        "work_request_id" => described_string_schema("Target WorkRequest id."),
        "body" =>
          markdown_string_schema("Non-secret Markdown comment body. Redacted before storage and response.")
          |> Map.put("maxLength", @local_operator_text_max_length),
        "created_by" =>
          described_string_schema("Local operator or agent provenance for audit display.")
          |> Map.put("maxLength", @local_operator_provenance_max_length)
      },
      ["work_request_id", "body", "created_by"]
    )
  end

  def local_operator_tool_input_schema("record_work_request_operator_decision") do
    schema(
      %{
        "work_request_id" => described_string_schema("Target WorkRequest id."),
        "decision" =>
          described_string_schema("Non-secret decision summary text. Redacted before storage and response.")
          |> Map.put("maxLength", @local_operator_text_max_length),
        "rationale" =>
          markdown_string_schema("Non-secret Markdown rationale for the decision.")
          |> Map.put("maxLength", @local_operator_text_max_length),
        "scope_impact" =>
          markdown_string_schema("Non-secret Markdown note on scope or delivery impact.")
          |> Map.put("maxLength", @local_operator_text_max_length),
        "created_by" =>
          described_string_schema("Local operator or agent provenance for audit display.")
          |> Map.put("maxLength", @local_operator_provenance_max_length),
        "source_id" =>
          described_string_schema("Optional local source id, such as a PR review or operator note id.")
          |> Map.put("maxLength", @local_operator_provenance_max_length)
      },
      ["work_request_id", "decision", "rationale", "scope_impact", "created_by"]
    )
  end

  @spec local_architect_assignment_claim_tool_input_schema() :: input_schema()
  def local_architect_assignment_claim_tool_input_schema do
    schema(
      %{
        "work_request_id" => string_schema(),
        "architect_anchor_work_package_id" => string_schema(),
        "repo" => string_schema(),
        "base_branch" => string_schema(),
        "phase_id" => string_schema(),
        "caller_id" => string_schema(),
        "claimed_by" => string_schema()
      },
      ["work_request_id"]
    )
  end

  @spec assignment_release_tool_input_schema() :: input_schema()
  def assignment_release_tool_input_schema do
    schema(%{"reason" => described_string_schema("Optional non-secret release reason; secrets are redacted before storage.")}, [])
  end

  @spec worker_tool_input_schema(tool_name()) :: input_schema()
  def worker_tool_input_schema(@local_assignment_claim_tool) do
    schema(
      %{
        "work_package_id" => string_schema(),
        "claimed_by" => string_schema()
      },
      ["work_package_id"]
    )
  end

  def worker_tool_input_schema(name) when name in ["get_current_assignment", "read_context", "read_task_plan"] do
    schema(%{}, [])
  end

  def worker_tool_input_schema("mark_ready") do
    schema(%{"blocker_closeout" => blocker_closeout_schema()}, [])
  end

  def worker_tool_input_schema("update_task_plan") do
    schema(
      session_scoped_properties(%{
        "body" => nullable_string_schema(),
        "expected_version" => integer_schema(),
        "id" => string_schema(),
        "patch" => plan_patch_schema(),
        "status" => string_schema(),
        "title" => string_schema()
      }),
      ["expected_version"]
    )
    |> always_validate(%{
      "oneOf" => [
        %{
          "required" => ["patch"],
          "not" => %{"anyOf" => [%{"required" => ["id"]}, %{"required" => ["title"]}, %{"required" => ["body"]}, %{"required" => ["status"]}]}
        },
        %{"required" => ["title"], "not" => %{"required" => ["patch"]}}
      ]
    })
  end

  def worker_tool_input_schema("append_finding") do
    schema(
      session_scoped_properties(%{
        "body" => markdown_string_schema("Human-facing finding details in Markdown."),
        "id" => string_schema(),
        "idempotency_key" => string_schema(),
        "severity" => string_schema(),
        "title" => string_schema()
      }),
      ["title", "body", "idempotency_key"]
    )
  end

  def worker_tool_input_schema(name) when name in ["append_progress", "request_scope_expansion"] do
    schema(progress_properties(), ["summary", "idempotency_key"])
  end

  def worker_tool_input_schema("report_blocker") do
    schema(Map.put(progress_properties(), "blocker_id", string_schema()), ["summary", "idempotency_key"])
  end

  def worker_tool_input_schema("resolve_blocker") do
    schema(
      progress_properties()
      |> Map.merge(%{"blocker_id" => string_schema(), "resolution" => string_schema()}),
      ["blocker_id", "resolution", "summary", "idempotency_key"]
    )
  end

  def worker_tool_input_schema("add_comment") do
    schema(
      session_scoped_properties(%{
        "target_kind" => string_enum_schema(Comment.target_kinds()),
        "target_id" => string_schema(),
        "body" => markdown_string_schema("Human-facing Markdown comment body.") |> Map.put("maxLength", Comment.max_body_length())
      }),
      ["body"]
    )
    |> require_comment_target_id_for_explicit_non_package_target()
  end

  def worker_tool_input_schema("list_comments") do
    schema(
      session_scoped_properties(%{
        "target_kind" => string_enum_schema(Comment.target_kinds()),
        "target_id" => string_schema()
      }),
      []
    )
    |> require_comment_target_id_for_explicit_non_package_target()
  end

  def worker_tool_input_schema("resolve_comment") do
    schema(
      session_scoped_properties(%{
        "comment_id" => string_schema(),
        "resolution_note" => markdown_string_schema("Optional Markdown resolution note.") |> Map.put("maxLength", Comment.max_resolution_note_length())
      }),
      ["comment_id"]
    )
  end

  def worker_tool_input_schema("create_guidance_request") do
    schema(
      session_scoped_properties(%{
        "summary" => string_schema(),
        "question" => markdown_string_schema("Human-facing guidance question in Markdown."),
        "context" => markdown_string_schema("Human-facing guidance context in Markdown."),
        "idempotency_key" => string_schema()
      }),
      ["summary", "question", "context", "idempotency_key"]
    )
  end

  def worker_tool_input_schema("read_guidance_request") do
    schema(session_scoped_properties(%{"guidance_request_id" => string_schema()}), ["guidance_request_id"])
  end

  def worker_tool_input_schema("set_status") do
    schema(session_scoped_properties(set_status_schema_properties()), ["status", "expected_status"])
  end

  def worker_tool_input_schema("attach_branch") do
    schema(metadata_properties(%{"branch" => string_schema(), "head_sha" => string_schema()}), ["branch", "head_sha"])
  end

  def worker_tool_input_schema("attach_pr") do
    schema(metadata_properties(pr_metadata_properties()), [])
    |> require_pr_identity_and_head()
  end

  def worker_tool_input_schema("sync_pr") do
    schema(metadata_properties(sync_pr_metadata_properties()), [])
  end

  def worker_tool_input_schema("submit_review_package") do
    schema(
      metadata_properties(%{
        "summary" => string_schema(),
        "tests" => nonempty_string_array_schema(),
        "artifacts" => nonempty_string_array_schema(),
        "head_sha" => string_schema(),
        "acceptance_criteria_met" => boolean_schema()
      }),
      ["summary", "tests", "artifacts"]
    )
  end

  def worker_tool_input_schema("complete_review") do
    schema(
      session_scoped_properties(%{
        "reference" => described_string_schema("Optional opaque provider or human review reference."),
        "note" => markdown_nullable_string_schema("Optional human-facing completion note.")
      }),
      []
    )
  end

  defp unbound_worker_tool_input_schema(name) when name in @session_scoped_worker_tools do
    name
    |> worker_tool_input_schema()
    |> put_in(["properties", "work_package_id"], string_schema())
  end

  defp unbound_worker_tool_input_schema(name), do: worker_tool_input_schema(name)

  defp set_status_schema_properties do
    %{
      "status" => string_schema(),
      "expected_status" => string_schema(),
      "reason" => nullable_string_schema(),
      "blocker_closeout" => blocker_closeout_schema()
    }
  end

  @spec architect_tool_input_schema(tool_name()) :: input_schema()
  def architect_tool_input_schema("create_child_work_package"), do: schema(%{"package" => object_schema()}, ["package"])

  def architect_tool_input_schema("mint_child_worker_key") do
    schema(%{"work_package_id" => string_schema(), "template" => object_schema()}, ["work_package_id"])
  end

  def architect_tool_input_schema("revoke_child_worker_key") do
    schema(%{"grant_id" => string_schema(), "reason" => string_schema()}, ["grant_id", "reason"])
  end

  def architect_tool_input_schema("list_work_requests"), do: schema(%{"status" => string_schema()}, [])

  def architect_tool_input_schema("read_work_request"), do: schema(%{"work_request_id" => string_schema()}, ["work_request_id"])

  def architect_tool_input_schema("read_plan") do
    schema(
      %{
        "work_request_id" => described_string_schema("Scoped WorkRequest id to project."),
        "view" =>
          @work_request_product_tree_views
          |> string_enum_schema()
          |> Map.put("description", "Projection size. Defaults to nodes_with_slice_refs.")
      },
      ["work_request_id"]
    )
  end

  def architect_tool_input_schema("list_comments") do
    schema(
      scoped_properties(%{
        "target_kind" => string_enum_schema(Comment.target_kinds()),
        "target_id" => string_schema()
      }),
      ["target_kind", "target_id"]
    )
  end

  def architect_tool_input_schema("read_delivery_board") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema()
      },
      []
    )
  end

  def architect_tool_input_schema("reconcile_work_request") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "apply" =>
          boolean_schema()
          |> Map.put("description", "When false or omitted, only report proposed closeout repairs. When true, apply through record_planned_slice_delivery."),
        "recorded_by" => described_string_schema("Optional closeout actor for applied repairs. Defaults to the claimed architect identity.")
      },
      []
    )
  end

  def architect_tool_input_schema(tool) when tool in ["cleanup_work_request_planned_slice_runtime", "revoke_planned_slice_worker_key"],
    do: delivery_runtime_tool_input_schema(tool)

  def architect_tool_input_schema("record_planned_slice_delivery") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "planned_slice_id" => described_string_schema("Planned slice id within the WorkRequest."),
        "outcome" =>
          PlannedSliceDelivery.outcomes()
          |> string_enum_schema()
          |> Map.put(
            "description",
            "Delivery outcome. Must match the single typed key inside evidence."
          ),
        "idempotency_key" => described_string_schema("Stable caller-provided key for replay. Reusing the same key and evidence returns the existing delivery; conflicting evidence is rejected."),
        "recorded_by" => described_string_schema("Optional closeout actor. Defaults to the claimed architect identity."),
        "evidence" => planned_slice_delivery_evidence_schema(),
        "blocker_closeout" => blocker_closeout_schema()
      },
      ["planned_slice_id", "outcome", "idempotency_key", "evidence"]
    )
  end

  def architect_tool_input_schema("add_comment") do
    schema(
      scoped_properties(%{
        "target_kind" => string_enum_schema(Comment.target_kinds()),
        "target_id" => string_schema(),
        "body" => markdown_string_schema("Human-facing Markdown comment body.") |> Map.put("maxLength", Comment.max_body_length())
      }),
      ["target_kind", "target_id", "body"]
    )
  end

  def architect_tool_input_schema("resolve_comment") do
    schema(
      scoped_properties(%{
        "comment_id" => string_schema(),
        "resolution_note" => markdown_string_schema("Optional Markdown resolution note.") |> Map.put("maxLength", Comment.max_resolution_note_length())
      }),
      ["comment_id"]
    )
  end

  def architect_tool_input_schema("resolve_blocker") do
    schema(
      progress_properties(:explicit)
      |> Map.merge(%{"blocker_id" => string_schema(), "resolution" => string_schema()}),
      ["blocker_id", "resolution", "summary", "idempotency_key"]
    )
  end

  def architect_tool_input_schema("list_guidance_requests") do
    schema(
      %{
        "status" => string_schema(),
        "work_package_id" => string_schema(),
        "work_request_id" =>
          described_string_schema(
            "Optional WorkRequest id whose linked WorkPackage guidance should be listed. When omitted from a current WorkRequest claim and work_package_id is also omitted, the current WorkRequest is used. Explicit values require read:work_request."
          )
      },
      []
    )
  end

  def architect_tool_input_schema("read_guidance_request") do
    schema(scoped_properties(%{"guidance_request_id" => string_schema()}), ["guidance_request_id"])
  end

  def architect_tool_input_schema("answer_guidance_request") do
    schema(
      %{
        "guidance_request_id" => string_schema(),
        "answer" => markdown_string_schema("Human-facing guidance answer in Markdown."),
        "answered_by" => string_schema()
      },
      ["guidance_request_id", "answer"]
    )
  end

  def architect_tool_input_schema("escalate_guidance_request") do
    schema(
      %{
        "guidance_request_id" => string_schema(),
        "reason" => markdown_string_schema("Human-facing escalation reason in Markdown."),
        "recommended_language" => markdown_string_schema("Recommended human-facing Markdown language."),
        "decision_prompt" => decision_prompt_schema()
      },
      ["guidance_request_id", "reason", "recommended_language"]
    )
  end

  def architect_tool_input_schema("set_work_request_status") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "current_status" => string_schema(),
        "next_status" => string_schema()
      },
      ["work_request_id", "current_status", "next_status"]
    )
  end

  def architect_tool_input_schema("ask_question") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "category" => string_schema(),
        "question" => markdown_string_schema("Human-facing clarification question in Markdown."),
        "why_needed" => markdown_string_schema("Human-facing Markdown explanation of why the answer is needed."),
        "decision_prompt" => decision_prompt_schema(),
        "asked_by_agent_run_id" => string_schema()
      },
      ["work_request_id", "category", "question", "why_needed"]
    )
  end

  def architect_tool_input_schema("answer_question") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "question_id" => string_schema(),
        "expected_question_status" => string_schema(),
        "current_status" => described_string_schema("Deprecated alias for expected_question_status."),
        "answer" => markdown_string_schema("Human-facing clarification answer in Markdown."),
        "answered_by" => string_schema()
      },
      ["work_request_id", "question_id", "answer"]
    )
  end

  def architect_tool_input_schema("answer_question_and_record_decision") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "question_id" => string_schema(),
        "expected_question_status" => string_schema(),
        "current_status" => described_string_schema("Deprecated alias for expected_question_status."),
        "answer" => markdown_string_schema("Human-facing clarification answer in Markdown."),
        "answered_by" => string_schema(),
        "source_type" => string_enum_schema(DecisionLogEntry.source_types()),
        "source_id" => string_schema(),
        "decision" => string_schema(),
        "rationale" => markdown_string_schema("Human-facing decision rationale in Markdown."),
        "scope_impact" => markdown_string_schema("Human-facing scope impact note in Markdown."),
        "created_by" => string_schema()
      },
      ["work_request_id", "question_id", "answer", "source_type", "decision", "rationale", "scope_impact"]
    )
  end

  def architect_tool_input_schema("close_question") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "question_id" => string_schema(),
        "expected_question_status" => string_schema(),
        "current_status" => described_string_schema("Deprecated alias for expected_question_status.")
      },
      ["work_request_id", "question_id"]
    )
  end

  def architect_tool_input_schema("record_decision") do
    schema(
      %{
        "work_request_id" => string_schema(),
        "source_type" => string_enum_schema(DecisionLogEntry.source_types()),
        "decision" => string_schema(),
        "rationale" => markdown_string_schema("Human-facing decision rationale in Markdown."),
        "scope_impact" => markdown_string_schema("Human-facing scope impact note in Markdown."),
        "created_by" => string_schema(),
        "source_id" => string_schema()
      },
      ["work_request_id", "source_type", "decision", "rationale", "scope_impact", "created_by"]
    )
  end

  def architect_tool_input_schema("plan_slice") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "title" => string_schema(),
        "goal" => string_schema(),
        "work_package_kind" => Map.put(string_enum_schema(WorkPackage.planned_slice_kinds()), "default", "standard_pr"),
        "delivery_repo" => described_string_schema("Optional delivery repo for this planned slice. Defaults to the parent WorkRequest primary repo and must be listed in the WorkRequest repo scopes."),
        "target_base_branch" =>
          described_string_schema(
            "Optional delivery base branch for the planned slice and created WorkPackage. Defaults to the selected WorkRequest base branch for its primary repo; pass it when selecting a secondary delivery repo. Worktree preparation must use the effective package base branch."
          ),
        "owned_file_globs" =>
          described_string_array_schema(
            "Repo-relative slash-separated owned file globs. `**` must be a complete path segment, for example `scripts/**/deploy*.ps1`; invalid examples include `scripts/**deploy**` and `packages/**kraken_batch**`."
          ),
        "forbidden_file_globs" => described_string_array_schema("Optional forbidden file globs. Defaults to an empty list."),
        "acceptance_criteria" => string_array_schema(),
        "validation_steps" => string_array_schema(),
        "review" => review_requirement_schema(),
        "stop_conditions" => string_array_schema(),
        "branch_pattern" => described_string_schema("Optional exact branch or {{placeholder}} template. Git wildcard patterns such as `*` are not supported.")
      },
      [
        "title",
        "goal",
        "owned_file_globs",
        "acceptance_criteria",
        "validation_steps",
        "stop_conditions"
      ]
    )
  end

  def architect_tool_input_schema("upsert_plan_node") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "product_tree_node_id" => described_string_schema("Optional existing product plan node id. Omit to create a new node."),
        "title" => nonblank_string_schema(),
        "description" => markdown_nullable_string_schema("Optional human-facing product plan node description."),
        "node_kind" => described_string_schema("Optional loose architect-facing grouping hint such as layer, capability, milestone, or risk."),
        "created_by" => described_string_schema("Optional architect identity for audit display.")
      },
      []
    )
    |> always_validate(%{
      "allOf" => [
        %{"anyOf" => [%{"required" => ["product_tree_node_id"]}, %{"required" => ["title"]}]},
        %{"anyOf" => [%{"required" => ["title"]}, %{"required" => ["description"]}, %{"required" => ["node_kind"]}]}
      ]
    })
  end

  def architect_tool_input_schema("move_plan_node") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "product_tree_node_id" => nonblank_string_schema(),
        "parent_id" =>
          nullable_string_schema()
          |> Map.put("description", "Target parent product plan node id. Omit to keep the current parent; pass null or an empty string to move the node to the WorkRequest root."),
        "position" => nonnegative_integer_schema(),
        "created_by" => described_string_schema("Optional architect identity for audit display.")
      },
      ["product_tree_node_id"]
    )
    |> always_validate(%{"anyOf" => [%{"required" => ["parent_id"]}, %{"required" => ["position"]}]})
  end

  def architect_tool_input_schema("set_plan_node_completion") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "product_tree_node_id" => nonblank_string_schema(),
        "completion_mark" => string_enum_schema(Node.completion_marks()),
        "created_by" => described_string_schema("Optional architect identity for audit display."),
        "blocker_closeout" => blocker_closeout_schema()
      },
      ["product_tree_node_id", "completion_mark"]
    )
  end

  def architect_tool_input_schema("move_slice_to_plan_node") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "planned_slice_id" => string_schema(),
        "product_tree_node_id" =>
          nullable_string_schema()
          |> Map.put("description", "Target product plan node id. Omit, null, or empty string to move the slice back to the WorkRequest's direct slice list."),
        "role" => string_enum_schema(SliceLink.roles()),
        "position" => nonnegative_integer_schema(),
        "created_by" => described_string_schema("Optional architect identity for audit display.")
      },
      ["planned_slice_id"]
    )
  end

  def architect_tool_input_schema(name) when name in ["approve_slice", "skip_slice"] do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "planned_slice_id" => string_schema(),
        "current_status" => string_schema()
      },
      ["planned_slice_id", "current_status"]
    )
  end

  def architect_tool_input_schema("finish_slicing") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "current_status" => string_schema()
      },
      ["current_status"]
    )
  end

  def architect_tool_input_schema("dispatch_slice") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "planned_slice_id" => string_schema(),
        "claimed_by" => described_string_schema("Optional claim display name to prefill worker bootstrap metadata.")
      },
      ["planned_slice_id"]
    )
  end

  def architect_tool_input_schema("prepare_work_package_worktree") do
    schema(
      %{
        "work_package_id" => string_schema(),
        "target_repo_root" => described_string_schema("Optional target product repository root. Omit when the current MCP repo root or a standard local checkout matches the WorkPackage repo."),
        "branch" => described_string_schema("Optional branch override, used only when the WorkPackage branch_pattern is a template or absent. Exact branch patterns are derived from the WorkPackage.")
      },
      ["work_package_id"]
    )
  end

  def architect_tool_input_schema("cleanup_work_package_worktree") do
    schema(
      %{
        "work_package_id" => string_schema(),
        "target_repo_root" => described_string_schema("Optional target product repository root override. Prepared worktrees remember the root used during prepare.")
      },
      ["work_package_id"]
    )
  end

  def architect_tool_input_schema("read_child_status"), do: schema(%{"work_package_id" => string_schema()}, ["work_package_id"])

  def architect_tool_input_schema("approve_scope_expansion") do
    schema(
      %{
        "work_package_id" => string_schema(),
        "allowed_file_globs" => nonempty_string_array_schema(),
        "request_id" => string_schema(),
        "rationale" => markdown_string_schema("Human-facing approval rationale in Markdown.")
      },
      ["work_package_id", "allowed_file_globs", "rationale"]
    )
  end

  def architect_tool_input_schema("read_phase_board"), do: schema(%{"phase_id" => string_schema()}, ["phase_id"])

  def architect_tool_input_schema("approve_child_ready_state") do
    schema(
      %{"work_package_id" => string_schema(), "rationale" => markdown_string_schema("Human-facing merge approval rationale in Markdown."), "request_id" => string_schema()},
      ["work_package_id", "rationale"]
    )
  end

  def architect_tool_input_schema("merge_child_into_phase"),
    do: schema(%{"work_package_id" => string_schema(), "merge_artifact" => merge_artifact_schema()}, ["work_package_id", "merge_artifact"])

  defp delivery_runtime_tool_input_schema("cleanup_work_request_planned_slice_runtime") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "planned_slice_id" => described_string_schema("Dispatched planned slice whose linked WorkPackage owns the runtime artifacts."),
        "outcome" =>
          ["superseded", "abandoned"]
          |> string_enum_schema()
          |> Map.put("description", "Delivery outcome being prepared. cleanup_work_request_planned_slice_runtime only supports superseded or abandoned closeout cleanup."),
        "reason" => described_string_schema("Redacted audit reason for recycling linked worker runtime before delivery closeout."),
        "successor_planned_slice_id" => described_string_schema("Required for outcome superseded; must belong to the same WorkRequest."),
        "successor_work_package_id" => described_string_schema("Optional successor package id; when present it must be linked to the declared successor planned slice inside the same WorkRequest."),
        "superseded_reason" => markdown_string_schema("Required Markdown reason for outcome superseded."),
        "abandoned_rationale" => markdown_string_schema("Required Markdown rationale for outcome abandoned.")
      },
      ["planned_slice_id", "outcome", "reason"]
    )
  end

  defp delivery_runtime_tool_input_schema("revoke_planned_slice_worker_key") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "planned_slice_id" => described_string_schema("Dispatched planned slice whose linked WorkPackage owns the worker grant."),
        "grant_id" => described_string_schema("Live worker grant id for the linked WorkPackage. Raw worker secrets are never accepted or returned."),
        "reason" => described_string_schema("Redacted audit reason for revoking the worker grant during recut, recycle, or delivery closeout cleanup.")
      },
      ["planned_slice_id", "grant_id", "reason"]
    )
  end

  defp planned_slice_delivery_evidence_schema do
    %{
      "type" => "object",
      "description" => "Exactly one typed evidence object matching outcome.",
      "additionalProperties" => false,
      "properties" => %{
        "pr_merged" =>
          schema(
            %{
              "pr_url" => described_string_schema("Merged pull request URL."),
              "pr_number" => integer_schema() |> Map.put("minimum", 1) |> Map.put("description", "Optional positive pull request number."),
              "pr_repository" => described_string_schema("Optional owner/repository."),
              "pr_merged_at" => described_string_schema("ISO-8601 merge timestamp."),
              "merge_commit_sha" => described_string_schema("Required for linked-package closeout strong evidence.")
            },
            ["pr_url", "pr_merged_at"]
          ),
        "completed_no_pr" =>
          schema(
            %{
              "no_pr_evidence" => markdown_string_schema("Markdown evidence for direct no-PR completion.")
            },
            ["no_pr_evidence"]
          ),
        "superseded" =>
          schema(
            %{
              "successor_planned_slice_id" => described_string_schema("Successor planned slice id in the same WorkRequest."),
              "successor_work_package_id" => described_string_schema("Optional successor package linked to the successor slice."),
              "superseded_reason" => markdown_string_schema("Markdown reason for supersession.")
            },
            ["successor_planned_slice_id", "superseded_reason"]
          ),
        "abandoned" =>
          schema(
            %{
              "abandoned_rationale" => markdown_string_schema("Markdown rationale for abandonment.")
            },
            ["abandoned_rationale"]
          )
      },
      "oneOf" => Enum.map(PlannedSliceDelivery.outcomes(), &%{"required" => [&1]})
    }
  end

  @spec claimable_tool_specs(Config.t()) :: [tool_spec()]
  def claimable_tool_specs(%Config{} = config) do
    [health_tool_spec()] ++
      local_assignment_claim_tool_specs(config) ++
      local_architect_assignment_claim_tool_specs(config)
  end

  @spec unbound_tool_specs_for_config(Config.t()) :: [tool_spec()]
  def unbound_tool_specs_for_config(%Config{} = config) do
    [health_tool_spec(), assignment_release_tool_spec()] ++
      Enum.map(@solo_tools, &solo_tool_spec/1) ++
      unbound_scoped_tool_specs() ++
      local_assignment_claim_tool_specs(config) ++
      local_architect_assignment_claim_tool_specs(config) ++
      Enum.map(@bootstrap_tools, &bootstrap_tool_spec/1)
  end

  @spec startup_tool_specs(:full | :worker | :architect | :coordinator | :solo, Config.t()) :: [tool_spec()]
  def startup_tool_specs(:full, %Config{} = config), do: config |> unbound_tool_specs_for_config() |> lean_tool_specs()

  def startup_tool_specs(:worker, %Config{}) do
    [worker_tool_spec(@local_assignment_claim_tool) | worker_session_tool_specs()]
    |> lean_tool_specs()
  end

  def startup_tool_specs(:architect, %Config{}) do
    [local_architect_assignment_claim_tool_spec() | architect_session_tool_specs(current_work_request?: true)]
    |> lean_tool_specs()
  end

  def startup_tool_specs(profile, %Config{}) when profile in [:coordinator, :solo] do
    [health_tool_spec(), assignment_release_tool_spec() | Enum.map(@solo_tools, &solo_tool_spec/1)]
    |> lean_tool_specs()
  end

  defp local_assignment_claim_tool_specs(%Config{}), do: [worker_tool_spec(@local_assignment_claim_tool)]

  defp local_architect_assignment_claim_tool_specs(%Config{}), do: [local_architect_assignment_claim_tool_spec()]

  defp architect_tool_specs(current_work_request?), do: Enum.map(@architect_tools, &architect_tool_spec(&1, current_work_request?))

  @spec architect_session_tool_specs(keyword()) :: [tool_spec()]
  def architect_session_tool_specs(opts \\ []) do
    current_work_request? = Keyword.get(opts, :current_work_request?, false)

    [
      health_tool_spec(),
      assignment_release_tool_spec(),
      worker_tool_spec("get_current_assignment")
      | architect_tool_specs(current_work_request?)
    ]
  end

  @spec worker_session_tool_specs() :: [tool_spec()]
  def worker_session_tool_specs do
    [health_tool_spec(), assignment_release_tool_spec() | Enum.map(@worker_tools, &worker_tool_spec/1)]
  end

  defp unbound_scoped_tool_specs do
    Enum.map(@architect_tools -- @shared_worker_architect_tools, &unbound_architect_tool_spec/1) ++
      Enum.map(@worker_tools -- @shared_worker_architect_tools, &unbound_worker_tool_spec/1) ++
      Enum.map(@shared_worker_architect_tools, &shared_worker_architect_tool_spec/1)
  end

  defp architect_tool_spec(name, true), do: architect_tool_spec(name)
  defp architect_tool_spec(name, false), do: explicit_work_request_architect_tool_spec(name)

  defp explicit_work_request_architect_tool_spec(name) when name in @current_work_request_tools do
    spec = architect_tool_spec(name)
    required = ["work_request_id" | architect_tool_input_schema(name)["required"]]

    spec
    |> Map.put("description", unbound_current_work_request_description(name))
    |> put_in(["inputSchema", "required"], required)
    |> put_in(["inputSchema", "properties", "work_request_id"], explicit_work_request_id_schema())
  end

  defp explicit_work_request_architect_tool_spec(name), do: architect_tool_spec(name)

  defp unbound_architect_tool_spec(name), do: explicit_work_request_architect_tool_spec(name)

  defp unbound_current_work_request_description(name) do
    name
    |> architect_tool_description()
    |> String.replace("the claimed current WorkRequest", "the explicit WorkRequest")
    |> String.replace("claimed current WorkRequest", "explicit WorkRequest")
  end

  defp shared_worker_architect_tool_spec(name), do: architect_tool_spec(name)

  @spec lean_tool_specs([tool_spec()]) :: [tool_spec()]
  def lean_tool_specs(specs), do: Enum.map(specs, &lean_tool_spec/1)

  defp lean_tool_spec(%{"name" => name, "description" => "Symphony++ worker tool " <> name_and_period} = spec) do
    if name_and_period == name <> ".", do: Map.drop(spec, ["title", "description"]), else: Map.delete(spec, "title")
  end

  defp lean_tool_spec(spec), do: Map.delete(spec, "title")

  @spec local_operator_tool_specs() :: [tool_spec()]
  def local_operator_tool_specs, do: Enum.map(@local_operator_tools, &local_operator_tool_spec/1)

  defp schema(properties, required) do
    %{"type" => "object", "additionalProperties" => false, "properties" => properties, "required" => required}
  end

  defp always_validate(schema, constraint), do: Map.merge(schema, %{"if" => %{}, "then" => constraint})

  defp require_pr_identity_and_head(schema) do
    always_validate(schema, %{
      "allOf" => [
        %{"anyOf" => [%{"required" => ["url"]}, %{"required" => ["number"]}]},
        %{
          "anyOf" => [
            %{"required" => ["head_sha"]},
            %{"required" => ["metadata"], "properties" => %{"metadata" => metadata_head_schema()}}
          ]
        }
      ]
    })
  end

  defp require_comment_target_id_for_explicit_non_package_target(schema) do
    Map.merge(schema, %{
      "if" => %{
        "required" => ["target_kind"],
        "properties" => %{"target_kind" => %{"enum" => ["work_request", "planned_slice"]}}
      },
      "then" => %{"required" => ["target_id"]}
    })
  end

  defp scoped_properties(properties), do: Map.put(properties, "work_package_id", string_schema())
  defp session_scoped_properties(properties), do: properties

  defp progress_properties(scope \\ :session)

  defp progress_properties(:session) do
    session_scoped_properties(%{
      "summary" => string_schema(),
      "body" => markdown_nullable_string_schema("Optional human-facing Markdown body."),
      "status" => string_schema(),
      "idempotency_key" => string_schema(),
      "payload" => object_schema()
    })
  end

  defp progress_properties(:explicit), do: progress_properties(:session) |> scoped_properties()

  defp metadata_properties(properties) do
    properties
    |> Map.merge(%{
      "body" => markdown_nullable_string_schema("Optional human-facing Markdown body."),
      "idempotency_key" => string_schema(),
      "payload" => object_schema(),
      "status" => string_schema(),
      "summary" => string_schema()
    })
    |> session_scoped_properties()
  end

  defp pr_metadata_properties do
    %{
      "url" => string_schema(),
      "number" => pr_number_schema(),
      "repository" => string_schema(),
      "head_sha" => string_schema(),
      "metadata" => object_schema()
    }
  end

  defp sync_pr_metadata_properties do
    Map.merge(pr_metadata_properties(), %{
      "branch" => string_schema(),
      "base_branch" => string_schema(),
      "base_sha" => string_schema(),
      "changed_files" => changed_files_schema(),
      "changed_files_count" => nonnegative_integer_schema(),
      "check_summary" => object_schema(),
      "review_state" => object_schema(),
      "merge_state" => object_schema(),
      "recovery" => object_schema()
    })
  end

  defp string_schema, do: %{"type" => "string"}
  defp described_string_schema(description), do: Map.put(string_schema(), "description", description)

  defp current_work_request_id_schema,
    do:
      described_string_schema(
        "Optional when the claimed architect WorkRequest session has exactly one current WorkRequest. When omitted, that WorkRequest is used; pass an explicit id for another authorized WorkRequest."
      )

  defp explicit_work_request_id_schema,
    do: described_string_schema("Required WorkRequest id. Compact current-WorkRequest omission is available only after claiming an architect WorkRequest.")

  defp markdown_string_schema(description), do: described_string_schema(description)
  defp string_enum_schema(values) when is_list(values), do: %{"type" => "string", "enum" => values}
  defp nonblank_string_schema, do: %{"type" => "string", "minLength" => 1, "pattern" => "\\S"}
  defp boolean_schema, do: %{"type" => "boolean"}
  defp integer_schema, do: %{"type" => "integer"}
  defp nonnegative_integer_schema, do: %{"type" => "integer", "minimum" => 0}

  defp pr_number_schema do
    %{"anyOf" => [%{"type" => "integer", "minimum" => 1}, %{"type" => "string", "pattern" => "^[1-9][0-9]*$"}]}
  end

  defp nullable_string_schema, do: %{"type" => ["string", "null"]}
  defp markdown_nullable_string_schema(description), do: Map.put(nullable_string_schema(), "description", description)
  defp object_schema, do: %{"type" => "object", "additionalProperties" => true}

  defp review_requirement_schema do
    %{
      "type" => "object",
      "description" => "Optional provider-agnostic review requirement. Omit when no review is required.",
      "additionalProperties" => false,
      "properties" => %{
        "type" => nonblank_string_schema() |> Map.put("description", "Opaque review provider or type."),
        "args" => object_schema() |> Map.put("description", "Optional opaque non-secret provider arguments.")
      },
      "required" => ["type"]
    }
  end

  defp blocker_closeout_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "decision" =>
          @blocker_closeout_decisions
          |> string_enum_schema()
          |> Map.put("description", "Use resolved when the active blockers are no longer true, or still_active when they must remain active after this finish transition."),
        "blocker_ids" =>
          string_array_schema()
          |> Map.put("description", "Optional explicit active blocker ids. Omit to apply the decision to every active blocker in scope."),
        "resolution" => markdown_string_schema("Required when decision is resolved. Human-facing note explaining why the blocker is clear."),
        "summary" => described_string_schema("Optional short audit summary for the blocker closeout decision.")
      },
      "required" => ["decision"]
    }
  end

  defp decision_prompt_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "tl_dr" => nonblank_string_schema(),
        "details" => nonblank_string_schema() |> Map.put("description", "Human-facing decision prompt details in Markdown."),
        "options" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 4,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "id" => nonblank_string_schema(),
              "label" => nonblank_string_schema(),
              "description" => nonblank_string_schema(),
              "pros" => string_array_schema(),
              "cons" => string_array_schema(),
              "answer" => nonblank_string_schema()
            },
            "required" => ["id", "label", "answer"]
          }
        },
        "custom_redirect_label" => nonblank_string_schema()
      },
      "required" => ["tl_dr", "details", "options"]
    }
  end

  defp nonempty_string_array_schema, do: %{"type" => "array", "minItems" => 1, "items" => nonblank_string_schema()}
  defp string_array_schema, do: %{"type" => "array", "items" => nonblank_string_schema()}
  defp described_string_array_schema(description), do: Map.put(string_array_schema(), "description", description)

  defp changed_files_schema,
    do: %{"anyOf" => [%{"type" => "array", "items" => %{"anyOf" => [nonblank_string_schema(), object_schema()]}}, nonnegative_integer_schema()]}

  defp metadata_head_schema do
    %{
      "type" => "object",
      "additionalProperties" => true,
      "properties" => %{
        "head_sha" => string_schema(),
        "head" => %{
          "type" => "object",
          "additionalProperties" => true,
          "properties" => %{"sha" => string_schema()},
          "required" => ["sha"]
        }
      },
      "anyOf" => [%{"required" => ["head_sha"]}, %{"required" => ["head"]}]
    }
  end

  defp merge_artifact_schema do
    %{
      "type" => "object",
      "additionalProperties" => true,
      "properties" => %{
        "status" => string_schema(),
        "uri" => string_schema(),
        "summary" => string_schema(),
        "commit_sha" => string_schema(),
        "merge_commit_sha" => string_schema()
      },
      "required" => ["status", "uri"]
    }
  end

  defp plan_patch_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "nodes" => %{
          "type" => "array",
          "minItems" => 1,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "properties" => %{
              "id" => string_schema(),
              "title" => string_schema(),
              "body" => nullable_string_schema(),
              "status" => string_schema()
            },
            "anyOf" => [
              %{"required" => ["title"]},
              %{
                "required" => ["id"],
                "anyOf" => [%{"required" => ["title"]}, %{"required" => ["body"]}, %{"required" => ["status"]}]
              }
            ]
          }
        }
      },
      "required" => ["nodes"]
    }
  end

  defp delivery_runtime_tool_description("cleanup_work_request_planned_slice_runtime"),
    do:
      "Recycle stale or superseded runtime authority for the WorkPackage linked to a scoped WorkRequest planned slice after superseded or abandoned delivery evidence is supplied. Revokes linked worker grants, releases non-paused local claim leases, clears recoverable worker MCP session bindings, and records audit evidence before delivery closeout."

  defp delivery_runtime_tool_description("revoke_planned_slice_worker_key"),
    do: "Revoke one live worker grant for the WorkPackage linked to a scoped WorkRequest planned slice during in-progress recycle or delivery closeout cleanup."
end
