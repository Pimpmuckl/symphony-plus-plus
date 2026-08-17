defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog.InputSchemas do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{SoloTools, ToolCatalog}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.{WorkPackage, WorkPackageDelivery}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{DecisionLogEntry, WorkRequest}

  @local_operator_provenance_max_length 512
  @type tool_name :: String.t()
  @type input_schema :: map()

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
          |> Map.put("maxLength", Comment.max_body_length()),
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
          |> Map.put("maxLength", Comment.max_body_length()),
        "rationale" =>
          markdown_string_schema("Non-secret Markdown rationale for the decision.")
          |> Map.put("maxLength", Comment.max_body_length()),
        "scope_impact" =>
          markdown_string_schema("Non-secret Markdown note on scope or delivery impact.")
          |> Map.put("maxLength", Comment.max_body_length()),
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

  def local_operator_tool_input_schema("summarize_failed_mcp_calls"), do: schema(%{}, [])

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
  def worker_tool_input_schema("claim_local_assignment") do
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
    schema(%{}, [])
  end

  def worker_tool_input_schema("update_task_plan") do
    schema(
      %{
        "expected_version" => integer_schema(),
        "nodes" => plan_nodes_schema()
      },
      ["expected_version", "nodes"]
    )
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

  def worker_tool_input_schema("add_comment") do
    schema(
      session_scoped_properties(%{
        "target_kind" => string_enum_schema(Comment.target_kinds()),
        "target_id" => string_schema(),
        "body" => markdown_string_schema("Human-facing Markdown comment body.") |> Map.put("maxLength", Comment.max_body_length())
      }),
      ["body"]
    )
    |> require_comment_target_id_for_explicit_work_request()
  end

  def worker_tool_input_schema("list_comments") do
    schema(
      session_scoped_properties(%{
        "target_kind" => string_enum_schema(Comment.target_kinds()),
        "target_id" => string_schema()
      }),
      []
    )
    |> require_comment_target_id_for_explicit_work_request()
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

  def worker_tool_input_schema("read_guidance_request") do
    schema(session_scoped_properties(%{"guidance_request_id" => string_schema()}), ["guidance_request_id"])
  end

  def worker_tool_input_schema("report_blocker") do
    schema(
      session_scoped_properties(%{
        "blocker_id" => described_string_schema("Optional stable blocker id. A deterministic id is generated when omitted."),
        "summary" => string_schema(),
        "body" => markdown_nullable_string_schema("Optional human-facing Markdown body."),
        "status" => string_enum_schema(["blocked"]),
        "idempotency_key" => string_schema(),
        "payload" => object_schema()
      }),
      ["summary", "idempotency_key"]
    )
  end

  def worker_tool_input_schema("resolve_blocker") do
    schema(
      session_scoped_properties(%{
        "blocker_id" => string_schema(),
        "resolution" => string_schema(),
        "summary" => string_schema(),
        "body" => markdown_nullable_string_schema("Optional human-facing Markdown body."),
        "status" => string_enum_schema(["resolved"]),
        "idempotency_key" => string_schema(),
        "payload" => object_schema()
      }),
      ["blocker_id", "resolution", "summary", "idempotency_key"]
    )
  end

  def worker_tool_input_schema("abandon"),
    do: schema(%{"reason" => markdown_string_schema("Why this work package is being abandoned.")}, ["reason"])

  def worker_tool_input_schema("attach_branch") do
    schema(metadata_properties(%{"branch" => string_schema(), "head_sha" => string_schema()}), ["head_sha"])
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
        "reference" =>
          nullable_string_schema()
          |> Map.put("description", "Optional opaque provider or human review reference."),
        "note" => markdown_nullable_string_schema("Optional human-facing completion note.")
      }),
      []
    )
  end

  @spec unbound_worker_tool_input_schema(tool_name()) :: input_schema()
  def unbound_worker_tool_input_schema("update_task_plan"), do: worker_tool_input_schema("update_task_plan")

  def unbound_worker_tool_input_schema(name) do
    schema = worker_tool_input_schema(name)

    if ToolCatalog.hidden_worker_argument_keys(name) == ["work_package_id"] do
      put_in(schema, ["properties", "work_package_id"], string_schema())
    else
      schema
    end
  end

  @spec architect_tool_input_schema(tool_name()) :: input_schema()
  def architect_tool_input_schema("create_child_work_package"), do: schema(%{"package" => object_schema()}, ["package"])

  def architect_tool_input_schema("mint_child_worker_key") do
    schema(%{"work_package_id" => string_schema(), "template" => object_schema()}, ["work_package_id"])
  end

  def architect_tool_input_schema("revoke_child_worker_key") do
    schema(%{"grant_id" => string_schema(), "reason" => string_schema()}, ["grant_id", "reason"])
  end

  def architect_tool_input_schema("list_work_requests") do
    schema(
      %{
        "status" => string_schema(),
        "limit" => integer_schema() |> Map.merge(%{"minimum" => 1, "maximum" => 200, "description" => "Page size. Defaults to 50; values above 200 are rejected."}),
        "cursor" => described_string_schema("Opaque cursor returned by the previous list_work_requests page.")
      },
      []
    )
  end

  def architect_tool_input_schema("read_work_request"), do: schema(%{"work_request_id" => string_schema()}, ["work_request_id"])

  def architect_tool_input_schema("read_plan") do
    schema(
      %{
        "work_request_id" => described_string_schema("Scoped WorkRequest id to project."),
        "view" =>
          ToolCatalog.work_request_product_tree_views()
          |> string_enum_schema()
          |> Map.put("description", "Projection size. Defaults to groups_with_work_package_refs.")
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
          |> Map.put("description", "When false or omitted, only report proposed closeout repairs. When true, apply through record_work_package_delivery."),
        "recorded_by" => described_string_schema("Optional closeout actor for applied repairs. Defaults to the claimed architect identity.")
      },
      []
    )
  end

  def architect_tool_input_schema(tool) when tool in ["cleanup_work_request_work_package_runtime", "revoke_work_package_worker_key"],
    do: delivery_runtime_tool_input_schema(tool)

  def architect_tool_input_schema("record_work_package_delivery") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => described_string_schema("WorkPackage id within the WorkRequest."),
        "outcome" =>
          WorkPackageDelivery.outcomes()
          |> string_enum_schema()
          |> Map.put(
            "description",
            "Delivery outcome. Must match the single typed key inside evidence."
          ),
        "idempotency_key" => described_string_schema("Stable caller-provided key for replay. Reusing the same key and evidence returns the existing delivery; conflicting evidence is rejected."),
        "recorded_by" => described_string_schema("Optional closeout actor. Defaults to the claimed architect identity."),
        "evidence" => work_package_delivery_evidence_schema()
      },
      ["work_package_id", "outcome", "idempotency_key", "evidence"]
    )
  end

  def architect_tool_input_schema("accept_review_rework") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => described_string_schema("Ordinary ready-for-merge WorkPackage with the accepted finding."),
        "idempotency_key" => described_string_schema("Opaque stable key for this accepted finding."),
        "evidence" =>
          schema(
            %{
              "provider" => described_string_schema("Provider or review system that produced the typed finding."),
              "reference" => described_string_schema("Opaque provider reference for the immutable evidence."),
              "head_sha" => described_string_schema("Exact current head of the attached PR."),
              "finding" => markdown_string_schema("Verified nonempty changes-required finding in Markdown.")
            },
            ["provider", "reference", "head_sha", "finding"]
          )
      },
      ["work_package_id", "idempotency_key", "evidence"]
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
      |> Map.merge(%{
        "blocker_id" => string_schema(),
        "resolution" => string_schema(),
        "status" => string_enum_schema(["resolved"])
      }),
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

  def architect_tool_input_schema("slice_work_request") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_packages" => %{
          "type" => "array",
          "minItems" => 1,
          "items" => work_package_contract_schema()
        }
      },
      ["work_packages"]
    )
  end

  def architect_tool_input_schema("update_work_package") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => nonblank_string_schema(),
        "expected_contract_revision" => positive_integer_schema(),
        "patch" => work_package_contract_patch_schema()
      },
      ["work_package_id", "expected_contract_revision", "patch"]
    )
  end

  def architect_tool_input_schema("upsert_group"), do: upsert_group_schema()

  def architect_tool_input_schema("delete_group") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "group_id" => nonblank_string_schema()
      },
      ["group_id"]
    )
  end

  def architect_tool_input_schema("upsert_dependency"), do: upsert_dependency_schema()

  def architect_tool_input_schema("delete_dependency") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "dependency_id" => nonblank_string_schema()
      },
      ["dependency_id"]
    )
  end

  def architect_tool_input_schema("skip_work_package") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => string_schema(),
        "current_status" => string_schema()
      },
      ["work_package_id", "current_status"]
    )
  end

  def architect_tool_input_schema("dispatch_work_package") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => string_schema(),
        "claimed_by" => described_string_schema("Optional claim display name to prefill worker bootstrap metadata.")
      },
      ["work_package_id"]
    )
  end

  def architect_tool_input_schema("prepare_work_package_worktree") do
    schema(
      %{
        "work_package_id" => string_schema(),
        "target_repo_root" => described_string_schema("Optional target product repository root. Omit when the current MCP repo root or a standard local checkout matches the WorkPackage repo."),
        "branch" =>
          described_string_schema("Optional branch override. Omit it to derive a package-unique branch from the WorkPackage id or branch_pattern template. Exact branch patterns are used unchanged.")
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

  defp delivery_runtime_tool_input_schema("cleanup_work_request_work_package_runtime") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => described_string_schema("Dispatched WorkPackage whose runtime artifacts are being cleaned up."),
        "outcome" =>
          ["superseded", "abandoned"]
          |> string_enum_schema()
          |> Map.put("description", "Delivery outcome being prepared. cleanup_work_request_work_package_runtime only supports superseded or abandoned closeout cleanup."),
        "reason" => described_string_schema("Redacted audit reason for recycling linked worker runtime before delivery closeout."),
        "successor_work_package_id" => described_string_schema("Required for outcome superseded; must belong to the same WorkRequest."),
        "superseded_reason" => markdown_string_schema("Required Markdown reason for outcome superseded."),
        "abandoned_rationale" => markdown_string_schema("Required Markdown rationale for outcome abandoned.")
      },
      ["work_package_id", "outcome", "reason"]
    )
  end

  defp delivery_runtime_tool_input_schema("revoke_work_package_worker_key") do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "work_package_id" => described_string_schema("Dispatched WorkPackage whose worker grant is being revoked."),
        "grant_id" => described_string_schema("Live worker grant id for the WorkPackage. Raw worker secrets are never accepted or returned."),
        "reason" => described_string_schema("Redacted audit reason for revoking the worker grant during recut, recycle, or delivery closeout cleanup.")
      },
      ["work_package_id", "grant_id", "reason"]
    )
  end

  defp work_package_delivery_evidence_schema do
    %{
      "type" => "object",
      "description" => "Exactly one typed evidence object matching outcome.",
      "oneOf" => Enum.map(WorkPackageDelivery.outcomes(), &work_package_delivery_outcome_evidence_schema/1)
    }
  end

  defp work_package_delivery_outcome_evidence_schema(outcome) do
    schema(%{outcome => work_package_delivery_typed_evidence_schema(outcome)}, [outcome])
  end

  defp work_package_delivery_typed_evidence_schema(outcome) do
    field_specs = WorkPackageDelivery.evidence_field_specs(outcome)

    properties =
      Map.new(field_specs, fn field_spec ->
        {field_spec.name, work_package_delivery_evidence_field_schema(field_spec)}
      end)

    required = for %{name: name, required: true} <- field_specs, do: name

    schema(properties, required)
  end

  defp work_package_delivery_evidence_field_schema(%{type: :string, description: description}),
    do: described_string_schema(description)

  defp work_package_delivery_evidence_field_schema(%{type: :positive_integer, description: description}),
    do: positive_integer_schema() |> Map.put("description", description)

  @spec explicit_work_request_architect_tool_input_schema(tool_name()) :: input_schema()
  def explicit_work_request_architect_tool_input_schema(name) do
    schema = architect_tool_input_schema(name)

    schema
    |> put_in(["required"], ["work_request_id" | schema["required"]])
    |> put_in(["properties", "work_request_id"], explicit_work_request_id_schema())
  end

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

  defp require_comment_target_id_for_explicit_work_request(schema) do
    Map.merge(schema, %{
      "if" => %{
        "required" => ["target_kind"],
        "properties" => %{"target_kind" => %{"enum" => ["work_request"]}}
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
    pr_metadata_properties()
    |> Map.take(~w(url number repository))
    |> Map.put("recovery", sync_pr_recovery_schema())
  end

  defp sync_pr_recovery_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "url" => string_schema(),
        "html_url" => string_schema(),
        "number" => pr_number_schema(),
        "repository" => string_schema(),
        "head_sha" => nonblank_string_schema(),
        "branch" => string_schema(),
        "base_branch" => string_schema(),
        "base_sha" => string_schema(),
        "changed_files" => changed_files_schema(),
        "changed_files_count" => nonnegative_integer_schema(),
        "check_summary" => canonical_status_schema(~w(passing failing pending unknown)),
        "review_state" => canonical_status_schema(~w(approved changes_requested review_required unknown)),
        "merge_state" => canonical_merge_state_schema(),
        "merged_at" => string_schema(),
        "merge_commit_sha" => string_schema(),
        "observed_at" => string_schema(),
        "provider_reference" => string_schema()
      },
      "allOf" => [
        %{"anyOf" => [%{"required" => ["url"]}, %{"required" => ["html_url"]}, %{"required" => ["number", "repository"]}]},
        %{"required" => ["head_sha"]}
      ]
    }
  end

  defp canonical_status_schema(statuses) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{"status" => string_enum_schema(statuses)},
      "required" => ["status"]
    }
  end

  defp canonical_merge_state_schema do
    canonical_status_schema(~w(merged clean blocked pending unknown))
    |> put_in(["properties", "merged"], boolean_schema())
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
  defp positive_integer_schema, do: %{"type" => "integer", "minimum" => 1}

  defp pr_number_schema do
    %{"anyOf" => [%{"type" => "integer", "minimum" => 1}, %{"type" => "string", "pattern" => "^[1-9][0-9]*$"}]}
  end

  defp nullable_string_schema, do: %{"type" => ["string", "null"]}
  defp markdown_nullable_string_schema(description), do: Map.put(nullable_string_schema(), "description", description)
  defp object_schema, do: %{"type" => "object", "additionalProperties" => true}

  defp work_package_contract_schema do
    schema(
      work_package_contract_properties(),
      ["title", "goal", "allowed_file_globs", "acceptance_criteria", "validation_steps", "stop_conditions"]
    )
  end

  defp work_package_contract_patch_schema do
    schema(work_package_contract_properties(), [])
    |> Map.put("minProperties", 1)
  end

  defp work_package_contract_properties do
    %{
      "group_id" => nullable_string_schema(),
      "title" => nonblank_string_schema(),
      "goal" => nonblank_string_schema(),
      "kind" => Map.put(string_enum_schema(WorkPackage.executable_kinds()), "default", "standard_pr"),
      "repo" => described_string_schema("Optional delivery repo. Defaults to the WorkRequest primary repo."),
      "base_branch" => described_string_schema("Optional delivery base branch. Defaults to the WorkRequest base branch."),
      "branch_pattern" => described_string_schema("Optional exact branch or {{placeholder}} template."),
      "allowed_file_globs" => described_string_array_schema("Repo-relative slash-separated owned file globs."),
      "forbidden_file_globs" => described_string_array_schema("Optional forbidden file globs."),
      "acceptance_criteria" => string_array_schema(),
      "validation_steps" => string_array_schema(),
      "review" => review_requirement_schema(),
      "stop_conditions" => string_array_schema()
    }
  end

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

  defp dependency_endpoint_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "kind" => string_enum_schema(["work_package", "group"]),
        "id" => nonblank_string_schema()
      },
      "required" => ["kind", "id"]
    }
  end

  defp upsert_group_schema do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "group_id" => described_string_schema("Optional existing Group id. Omit to create a Group."),
        "title" => nonblank_string_schema(),
        "description" => markdown_nullable_string_schema("Optional human-facing Group description."),
        "kind" => described_string_schema("Optional loose organization hint such as capability, milestone, or risk."),
        "parent_group_id" => nullable_string_schema() |> Map.put("description", "Optional parent Group id; pass null to move the Group to the WorkRequest root."),
        "position" => nonnegative_integer_schema(),
        "created_by" => described_string_schema("Optional architect identity for audit display.")
      },
      []
    )
    |> always_validate(%{
      "allOf" => [
        %{"anyOf" => [%{"required" => ["group_id"]}, %{"required" => ["title"]}]},
        %{
          "anyOf" => Enum.map(["title", "description", "kind", "parent_group_id", "position"], &%{"required" => [&1]})
        }
      ]
    })
  end

  defp upsert_dependency_schema do
    schema(
      %{
        "work_request_id" => current_work_request_id_schema(),
        "dependency_id" => described_string_schema("Optional existing dependency id. Omit to create a dependency."),
        "dependent" => dependency_endpoint_schema(),
        "prerequisite" => dependency_endpoint_schema(),
        "reason" => markdown_string_schema("Why this dependency exists."),
        "decision_ref" => object_schema(),
        "created_by" => described_string_schema("Optional architect identity for audit display.")
      },
      ["dependent", "prerequisite"]
    )
    |> always_validate(%{"anyOf" => [%{"required" => ["reason"]}, %{"required" => ["decision_ref"]}]})
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

  defp plan_nodes_schema do
    %{
      "type" => "array",
      "minItems" => 1,
      "items" => %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" => %{
          "id" => nonblank_string_schema(),
          "title" => nonblank_string_schema(),
          "body" => nullable_string_schema(),
          "status" => string_enum_schema(PlanNode.statuses())
        }
      }
    }
  end
end
