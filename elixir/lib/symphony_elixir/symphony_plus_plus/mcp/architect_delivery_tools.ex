defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ArchitectDeliveryTools do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_boolean: 3,
      optional_positive_integer_argument: 2,
      optional_string_argument: 2,
      optional_string_argument: 3,
      required_argument: 2,
      required_object: 2
    ]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Auth,
    BlockerCloseout,
    Config,
    CurrentWorkRequest,
    Payloads,
    PlannedSliceWorkerRevoke,
    ProgressEvents,
    Session,
    ToolResult,
    WorkRequestPayloads,
    WorkRequestScope
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryReconciler
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceLinkage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.RuntimeCleanup, as: WorkRequestRuntimeCleanup
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @child_worker_capabilities ["worker:claim", "worker:lifecycle.transition"]
  @child_worker_grant_provenance "child_worker_delegation"

  @type repo :: module()
  @type tool_response :: {:ok, map()} | {:error, integer(), String.t(), map()}
  @type service_response :: {:ok, term()} | {:tool_error, term()} | {:error, term()}

  @spec call(String.t(), map(), Config.t(), Session.t() | nil) :: tool_response()
  def call("reconcile_work_request", %{} = arguments, %Config{} = config, session) do
    with {:ok, apply?} <- optional_boolean(arguments, "apply", false),
         {:ok, live_session} <- Auth.require_session(session, config.repo),
         :ok <- require_delivery_reconcile_capability(live_session, apply?),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, live_session),
         {:ok, recorded_by} <- optional_string_argument(arguments, "recorded_by", session_claimed_by(live_session)),
         {:ok, work_request, filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(
             config.repo,
             live_session,
             work_request_id,
             reconcile_work_request_action(apply?),
             "reconcile_work_request"
           ),
         {:ok, planned_slices} <- WorkRequestService.list_planned_slices(config.repo, work_request_id),
         {visible_work_package_ids, work_package_contexts} <-
           WorkRequestScope.visible_delivery_board_work_package_contexts(config.repo, work_request, planned_slices, filters),
         {:ok, reconciliation} <-
           reconcile_work_request(config.repo, live_session, work_request_id, apply?, recorded_by,
             mode: reconcile_work_request_mode(apply?),
             work_request: work_request,
             planned_slices: planned_slices,
             visible_work_package_ids: visible_work_package_ids,
             work_package_contexts: work_package_contexts
           ) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
         "reconciliation" => Payloads.reconciliation_payload(reconciliation),
         "delivery_board" => WorkRequestPayloads.delivery_board(Map.fetch!(reconciliation, :delivery_board)),
         "scope" => scope
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "reconcile_work_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("reconcile_work_request")
      {:error, reason} -> architect_error(reason, "reconcile_work_request")
    end
  end

  def call("record_planned_slice_delivery", %{} = arguments, %Config{} = config, session) do
    with {:ok, live_session} <- Auth.require_session(session, config.repo),
         :ok <- require_delivery_write_capability(live_session),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, live_session),
         {:ok, planned_slice_id} <- required_argument(arguments, "planned_slice_id"),
         {:ok, outcome} <- required_planned_slice_delivery_outcome(arguments),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, recorded_by} <- optional_string_argument(arguments, "recorded_by", session_claimed_by(live_session)),
         {:ok, attrs} <- planned_slice_delivery_attrs(arguments, outcome, idempotency_key, recorded_by),
         {:ok, work_request, planned_slice, filters, scope} <-
           WorkRequestScope.authorized_planned_slice_scope(
             config.repo,
             live_session,
             work_request_id,
             planned_slice_id,
             :delivery_closeout_record,
             "record_planned_slice_delivery"
           ),
         :ok <- require_planned_slice_delivery_scope(config.repo, work_request, planned_slice, attrs, filters),
         {:ok, attrs, blocker_closeout_plan} <-
           maybe_prepare_slice_delivery_blocker_closeout(config.repo, live_session, planned_slice, arguments, attrs),
         {:ok, {delivery, blocker_closeout}} <-
           mutate_product_tree(
             config.repo,
             work_request_id,
             "record_planned_slice_delivery",
             recorded_by,
             fn ->
               record_planned_slice_delivery_with_blocker_closeout(
                 config.repo,
                 live_session,
                 work_request_id,
                 planned_slice_id,
                 attrs,
                 blocker_closeout_plan
               )
             end
           ),
         {:ok, planned_slices} <- WorkRequestService.list_planned_slices(config.repo, work_request_id),
         {:ok, delivery_board} <- WorkRequestScope.scoped_delivery_board(config.repo, work_request, planned_slices, filters) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
         "planned_slice_delivery" => WorkRequestPayloads.planned_slice_delivery(delivery),
         "blocker_closeout" => blocker_closeout,
         "delivery_board" => WorkRequestPayloads.delivery_board(delivery_board),
         "scope" => scope
       })}
    else
      {:tool_error, reason} -> invalid_params_error("record_planned_slice_delivery", reason)
      {:error, :not_found} -> not_found_error("record_planned_slice_delivery")
      {:error, reason} -> record_planned_slice_delivery_error(reason)
    end
  end

  def call("cleanup_work_request_planned_slice_runtime", %{} = arguments, %Config{} = config, session) do
    with {:ok, live_session} <- Auth.require_session(session, config.repo),
         :ok <- require_delivery_write_capability(live_session),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, live_session),
         {:ok, planned_slice_id} <- required_argument(arguments, "planned_slice_id"),
         {:ok, outcome} <- required_runtime_cleanup_delivery_outcome(arguments),
         {:ok, reason} <- required_argument(arguments, "reason"),
         {:ok, delivery_evidence} <-
           runtime_cleanup_delivery_evidence_attrs(arguments, outcome, work_request_id, planned_slice_id),
         {:ok, work_request, planned_slice, filters, scope} <-
           WorkRequestScope.authorized_planned_slice_scope(
             config.repo,
             live_session,
             work_request_id,
             planned_slice_id,
             :work_package_repair_state,
             "cleanup_work_request_planned_slice_runtime"
           ),
         :ok <- require_planned_slice_delivery_scope(config.repo, work_request, planned_slice, delivery_evidence, filters),
         {:ok, work_package_id} <- WorkRequestScope.planned_slice_work_package_id(config.repo, work_request, planned_slice),
         {:ok, cleanup} <-
           run_architect_transaction(config.repo, fn ->
             cleanup_work_request_planned_slice_runtime_in_transaction(
               config.repo,
               live_session,
               work_request,
               planned_slice,
               work_package_id,
               reason,
               delivery_evidence,
               filters
             )
           end) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
         "planned_slice" => WorkRequestPayloads.planned_slice(planned_slice),
         "work_package" => Payloads.child_work_package_payload(Map.fetch!(cleanup, :work_package)),
         "runtime_cleanup" => Map.fetch!(cleanup, :runtime_cleanup),
         "audit_event" => ProgressEvents.payload(Map.fetch!(cleanup, :audit_event)),
         "scope" => scope
       })}
    else
      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "cleanup_work_request_planned_slice_runtime", "reason" => reason}}

      {:error, :not_found} ->
        not_found_error("cleanup_work_request_planned_slice_runtime")

      {:error, reason} ->
        work_request_runtime_cleanup_error(reason)
    end
  end

  def call("revoke_planned_slice_worker_key", %{} = arguments, %Config{} = config, session) do
    with {:ok, live_session} <- Auth.require_session(session, config.repo),
         :ok <- require_delivery_write_capability(live_session),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, live_session),
         {:ok, planned_slice_id} <- required_argument(arguments, "planned_slice_id"),
         {:ok, grant_id} <- required_argument(arguments, "grant_id"),
         {:ok, reason} <- required_argument(arguments, "reason"),
         {:ok, work_request, planned_slice, filters, scope} <-
           WorkRequestScope.authorized_planned_slice_scope(
             config.repo,
             live_session,
             work_request_id,
             planned_slice_id,
             :work_package_repair_state,
             "revoke_planned_slice_worker_key"
           ),
         {:ok, work_package_id} <- WorkRequestScope.planned_slice_work_package_id(config.repo, work_request, planned_slice),
         {:ok, payload} <-
           run_architect_transaction(config.repo, fn ->
             revoke_planned_slice_worker_key_in_transaction(
               config.repo,
               live_session,
               work_request,
               planned_slice,
               work_package_id,
               grant_id,
               reason,
               filters
             )
           end) do
      {:ok, ToolResult.tool_result(Map.put(payload, "scope", scope))}
    else
      {:tool_error, reason} ->
        planned_slice_worker_revoke_tool_error(reason)

      {:error, :not_found} ->
        not_found_error("revoke_planned_slice_worker_key")

      {:error, reason} ->
        architect_error(reason, "revoke_planned_slice_worker_key")
    end
  end

  @spec cleanup_worktree_runtime(repo(), Session.t(), WorkPackage.t()) :: service_response()
  def cleanup_worktree_runtime(repo, %Session{} = session, %WorkPackage{} = work_package) do
    run_architect_transaction(repo, fn ->
      cleanup_worktree_runtime_in_transaction(repo, session, work_package.id)
    end)
  end

  @spec append_worktree_lifecycle_audit(repo(), Session.t(), String.t(), String.t(), map()) ::
          {:ok, term()} | {:error, term()}
  def append_worktree_lifecycle_audit(repo, %Session{} = session, work_package_id, source_tool, result) do
    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, work_package_id, %{
      "summary" => worktree_lifecycle_summary(source_tool, result.status),
      "status" => result.status,
      "idempotency_key" => worktree_lifecycle_idempotency_key(work_package_id, source_tool, result),
      "payload" => %{
        "type" => "worktree_lifecycle",
        "source_tool" => source_tool,
        "work_package_id" => work_package_id,
        "worktree_path" => audit_local_path(result.worktree_path),
        "target_repo_root" => audit_local_path(result.target_repo_root || result.repo_root),
        "branch" => result.branch,
        "base_branch" => result.base_branch,
        "status" => result.status
      }
    })
  end

  @spec maybe_append_cleanup_worktree_audit(repo(), Session.t(), String.t(), map()) ::
          {:ok, term() | nil} | {:error, term()}
  def maybe_append_cleanup_worktree_audit(_repo, _session, _work_package_id, %{status: "already_clean"}), do: {:ok, nil}

  def maybe_append_cleanup_worktree_audit(repo, %Session{} = session, work_package_id, result) do
    append_worktree_lifecycle_audit(repo, session, work_package_id, "cleanup_work_package_worktree", result)
  end

  defp cleanup_worktree_runtime_in_transaction(repo, %Session{} = session, work_package_id) do
    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, _architect_grant} <- WorkRequestScope.require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, work_request, planned_slice} <- cleanup_worktree_runtime_scope(repo, work_package_id),
         true <- cleanup_worktree_claim_only_runtime?(repo, work_package_id) do
      WorkRequestRuntimeCleanup.cleanup(
        repo,
        work_request,
        planned_slice,
        work_package,
        session.assignment,
        reason: "cleanup_work_package_worktree",
        delivery_evidence: %{"outcome" => "worktree_cleanup"}
      )
    else
      false -> {:ok, nil}
      {:error, :not_found} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_worktree_runtime_scope(repo, work_package_id) do
    query =
      from(planned_slice in PlannedSlice,
        join: work_request in WorkRequest,
        on: work_request.id == planned_slice.work_request_id,
        where: planned_slice.work_package_id == ^work_package_id,
        select: {work_request, planned_slice},
        limit: 1
      )

    case repo.one(query) do
      {%WorkRequest{} = work_request, %PlannedSlice{} = planned_slice} -> {:ok, work_request, planned_slice}
      nil -> {:error, :not_found}
    end
  end

  defp cleanup_worktree_claim_only_runtime?(repo, work_package_id) do
    now = DateTime.utc_now(:microsecond)
    context = WorkPackageActivity.context(repo, work_package_id)
    reason_codes = List.wrap(get_in(context, [:runtime_state, :reason_codes]))

    with {:ok, grants} <- AccessGrantRepository.list_for_work_package(repo, work_package_id) do
      not Enum.any?(grants, &live_worker_grant?(&1, now)) and get_in(context, [:runtime_state, :paused?]) != true and
        reason_codes -- ["claim_lease_active", "claim_lease_stale", "worker_recycled", "package_terminal"] == []
    end
  end

  defp live_worker_grant?(%AccessGrant{grant_role: "worker", revoked_at: nil, expires_at: nil}, _now), do: true

  defp live_worker_grant?(%AccessGrant{grant_role: "worker", revoked_at: nil, expires_at: %DateTime{} = expires_at}, now) do
    DateTime.compare(expires_at, now) == :gt
  end

  defp live_worker_grant?(%AccessGrant{}, _now), do: false

  defp record_planned_slice_delivery_error(%Ecto.Changeset{} = changeset) do
    changeset_invalid_params_error("record_planned_slice_delivery", "invalid_planned_slice_delivery", changeset)
  end

  defp record_planned_slice_delivery_error(reason)
       when reason in [:delivery_outcome_conflict, :missing_strong_pr_evidence, :idempotency_key_conflict] do
    {:error, -32_602, "Invalid params", %{"tool" => "record_planned_slice_delivery", "reason" => Atom.to_string(reason)}}
  end

  defp record_planned_slice_delivery_error(reason) when reason in [:active_runtime, :claim_not_current, :work_package_not_abandonable] do
    delivery_closeout_precondition_error("record_planned_slice_delivery", reason)
  end

  defp record_planned_slice_delivery_error(reason), do: architect_error(reason, "record_planned_slice_delivery")

  defp work_request_runtime_cleanup_error(reason) do
    if runtime_cleanup_precondition_error?(reason) do
      delivery_closeout_precondition_error(
        "cleanup_work_request_planned_slice_runtime",
        runtime_cleanup_precondition_reason(reason)
      )
    else
      architect_error(reason, "cleanup_work_request_planned_slice_runtime")
    end
  end

  defp runtime_cleanup_precondition_error?(reason) do
    reason in [:active_runtime, :claim_not_current, :worker_grant_revoke_conflict, :mcp_session_binding_conflict]
  end

  defp runtime_cleanup_precondition_reason(:worker_grant_revoke_conflict), do: :claim_not_current
  defp runtime_cleanup_precondition_reason(:mcp_session_binding_conflict), do: :claim_not_current
  defp runtime_cleanup_precondition_reason(reason), do: reason

  defp planned_slice_worker_revoke_tool_error(reason)
       when reason == "planned_slice_worker_revoke_conflict" do
    delivery_closeout_precondition_error("revoke_planned_slice_worker_key", :claim_not_current)
  end

  defp planned_slice_worker_revoke_tool_error(reason) do
    {:error, -32_602, "Invalid params", %{"tool" => "revoke_planned_slice_worker_key", "reason" => reason}}
  end

  defp delivery_closeout_precondition_error(tool, :claim_not_current) do
    precondition_error(tool, "runtime_lease_conflict")
  end

  defp delivery_closeout_precondition_error(tool, reason) when is_atom(reason) do
    precondition_error(tool, Atom.to_string(reason))
  end

  defp precondition_error(tool, reason) do
    {:error, -32_009, "Precondition Failed",
     %{
       "tool" => tool,
       "reason" => reason,
       "reason_code" => reason,
       "decision_reason" => "precondition_denied",
       "next_action" => precondition_next_action(tool, reason)
     }}
  end

  defp precondition_next_action("record_planned_slice_delivery", "active_runtime"),
    do: "release_worker_or_retry_after_stale"

  defp precondition_next_action("record_planned_slice_delivery", _reason),
    do: "retry_record_planned_slice_delivery"

  defp precondition_next_action(_tool, _reason), do: "retry_after_runtime_state_changes"

  defp audit_local_path(nil), do: nil
  defp audit_local_path(_path), do: "[REDACTED]"

  defp worktree_lifecycle_summary("prepare_work_package_worktree", "already_prepared"), do: "WorkPackage worktree already prepared"
  defp worktree_lifecycle_summary("prepare_work_package_worktree", _status), do: "Prepared WorkPackage worktree"
  defp worktree_lifecycle_summary("cleanup_work_package_worktree", _status), do: "Success removing worktree. Subagent can be closed now."

  defp worktree_lifecycle_idempotency_key(work_package_id, source_tool, result) do
    fingerprint =
      :sha256
      |> :crypto.hash([to_string(result.status), "\0", to_string(result.worktree_path), "\0", to_string(result.branch)])
      |> Base.url_encode64(padding: false)

    "worktree_lifecycle:#{source_tool}:#{work_package_id}:#{fingerprint}"
  end

  defp required_planned_slice_delivery_outcome(arguments) do
    with {:ok, outcome} <- required_argument(arguments, "outcome") do
      if outcome in PlannedSliceDelivery.outcomes() do
        {:ok, outcome}
      else
        {:tool_error, "invalid_outcome"}
      end
    end
  end

  defp required_runtime_cleanup_delivery_outcome(arguments) do
    with {:ok, outcome} <- required_argument(arguments, "outcome") do
      if outcome in ["superseded", "abandoned"] do
        {:ok, outcome}
      else
        {:tool_error, "invalid_outcome"}
      end
    end
  end

  defp runtime_cleanup_delivery_evidence_attrs(arguments, outcome, work_request_id, planned_slice_id) do
    with {:ok, successor_planned_slice_id} <- optional_string_argument(arguments, "successor_planned_slice_id"),
         {:ok, successor_work_package_id} <- optional_string_argument(arguments, "successor_work_package_id"),
         {:ok, superseded_reason} <- optional_string_argument(arguments, "superseded_reason"),
         {:ok, abandoned_rationale} <- optional_string_argument(arguments, "abandoned_rationale") do
      attrs =
        %{
          "work_request_id" => work_request_id,
          "planned_slice_id" => planned_slice_id,
          "outcome" => outcome,
          "idempotency_key" => "runtime-cleanup-evidence"
        }
        |> optional_put("successor_planned_slice_id", successor_planned_slice_id)
        |> optional_put("successor_work_package_id", successor_work_package_id)
        |> optional_put("superseded_reason", superseded_reason)
        |> optional_put("abandoned_rationale", abandoned_rationale)

      validate_runtime_cleanup_delivery_evidence(attrs)
    end
  end

  defp validate_runtime_cleanup_delivery_evidence(attrs) do
    case attrs |> PlannedSliceDelivery.create_changeset() |> Ecto.Changeset.apply_action(:insert) do
      {:ok, _delivery} -> {:ok, attrs}
      {:error, _changeset} -> {:tool_error, "invalid_delivery_evidence"}
    end
  end

  defp planned_slice_delivery_attrs(arguments, outcome, idempotency_key, recorded_by) do
    with {:ok, evidence} <- required_object(arguments, "evidence"),
         {:ok, evidence_attrs} <- planned_slice_delivery_evidence_attrs(evidence, outcome) do
      {:ok,
       Map.merge(
         %{
           "outcome" => outcome,
           "idempotency_key" => idempotency_key,
           "recorded_by" => recorded_by
         },
         evidence_attrs
       )}
    end
  end

  defp planned_slice_delivery_evidence_attrs(evidence, outcome) do
    case Map.keys(evidence) do
      [^outcome] ->
        with {:ok, typed_evidence} <- required_object(evidence, outcome) do
          planned_slice_delivery_typed_evidence_attrs(outcome, typed_evidence)
        end

      [] ->
        {:tool_error, "missing_evidence"}

      _keys ->
        {:tool_error, "conflicting_delivery_evidence"}
    end
  end

  defp planned_slice_delivery_typed_evidence_attrs(outcome, evidence) do
    field_specs = planned_slice_delivery_evidence_field_specs(outcome)
    allowed_keys = Enum.map(field_specs, &elem(&1, 0))

    with :ok <- require_planned_slice_delivery_evidence_fields(evidence, allowed_keys) do
      collect_planned_slice_delivery_evidence_attrs(evidence, field_specs)
    end
  end

  defp planned_slice_delivery_evidence_field_specs("pr_merged"),
    do: [
      {"pr_url", :string},
      {"pr_number", :positive_integer},
      {"pr_repository", :string},
      {"pr_merged_at", :string},
      {"merge_commit_sha", :string}
    ]

  defp planned_slice_delivery_evidence_field_specs("completed_no_pr"), do: [{"no_pr_evidence", :string}]

  defp planned_slice_delivery_evidence_field_specs("superseded"),
    do: [
      {"successor_planned_slice_id", :string},
      {"successor_work_package_id", :string},
      {"superseded_reason", :string}
    ]

  defp planned_slice_delivery_evidence_field_specs("abandoned"), do: [{"abandoned_rationale", :string}]

  defp collect_planned_slice_delivery_evidence_attrs(evidence, field_specs) do
    Enum.reduce_while(field_specs, {:ok, %{}}, fn {field, type}, {:ok, attrs} ->
      case planned_slice_delivery_evidence_field(evidence, field, type) do
        {:ok, value} -> {:cont, {:ok, optional_put(attrs, field, value)}}
        {:tool_error, reason} -> {:halt, {:tool_error, reason}}
      end
    end)
  end

  defp planned_slice_delivery_evidence_field(evidence, field, :string), do: optional_string_argument(evidence, field)
  defp planned_slice_delivery_evidence_field(evidence, field, :positive_integer), do: optional_positive_integer_argument(evidence, field)

  defp require_planned_slice_delivery_evidence_fields(evidence, allowed_keys) do
    case Map.keys(evidence) -- allowed_keys do
      [] -> :ok
      _unexpected -> {:tool_error, "invalid_evidence"}
    end
  end

  defp maybe_prepare_slice_delivery_blocker_closeout(
         repo,
         %Session{} = session,
         %PlannedSlice{work_package_id: work_package_id},
         arguments,
         attrs
       ) do
    case BlockerCloseout.prepare_scoped(repo, session, [work_package_id], arguments, "record_planned_slice_delivery") do
      {:ok, closeout_plan} ->
        attrs =
          if BlockerCloseout.decision(closeout_plan) == "still_active" do
            Map.put(attrs, "allow_active_blocker_closeout", true)
          else
            attrs
          end

        {:ok, attrs, closeout_plan}

      {:tool_error, reason} ->
        {:tool_error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp record_planned_slice_delivery_with_blocker_closeout(
         repo,
         %Session{} = session,
         work_request_id,
         planned_slice_id,
         attrs,
         blocker_closeout_plan
       ) do
    with {:ok, blocker_closeout} <- BlockerCloseout.apply(repo, session, blocker_closeout_plan),
         {:ok, delivery} <-
           WorkRequestService.record_planned_slice_delivery(
             repo,
             work_request_id,
             planned_slice_id,
             attrs
           ) do
      {:ok, {delivery, blocker_closeout}}
    end
  end

  defp reconcile_work_request_action(true), do: :delivery_reconcile_apply
  defp reconcile_work_request_action(false), do: :delivery_reconcile_dry_run

  defp require_delivery_reconcile_capability(%Session{} = session, apply?) do
    if WorkRequestScope.architect_session?(session) do
      require_architect_capability(session.assignment, reconcile_work_request_capability(apply?))
    else
      :ok
    end
  end

  defp require_delivery_write_capability(%Session{} = session) do
    if WorkRequestScope.architect_session?(session) do
      require_architect_capability(session.assignment, "write:work_request")
    else
      :ok
    end
  end

  defp reconcile_work_request_capability(true), do: "write:work_request"
  defp reconcile_work_request_capability(false), do: "read:work_request"

  defp reconcile_work_request_mode(true), do: :apply
  defp reconcile_work_request_mode(false), do: :dry_run

  defp reconcile_work_request(repo, %Session{} = session, work_request_id, true = _apply?, recorded_by, opts) do
    opts = Keyword.put(opts, :recorded_by, recorded_by)
    opts = Keyword.put(opts, :append_blocker_closeout_event, reconcile_blocker_closeout_appender(session))

    run_architect_transaction(repo, fn ->
      with {:ok, reconciliation} <- DeliveryReconciler.reconcile(repo, work_request_id, opts) do
        record_reconcile_product_tree_revision_after_apply(repo, work_request_id, recorded_by, reconciliation)
      end
    end)
  end

  defp reconcile_work_request(repo, %Session{}, work_request_id, false = _apply?, recorded_by, opts) do
    opts = Keyword.put(opts, :recorded_by, recorded_by)

    DeliveryReconciler.reconcile(repo, work_request_id, opts)
  end

  defp record_reconcile_product_tree_revision_after_apply(
         repo,
         work_request_id,
         recorded_by,
         reconciliation
       ) do
    with {:ok, _revision} <-
           maybe_record_reconcile_product_tree_revision(
             repo,
             work_request_id,
             recorded_by,
             reconciliation
           ) do
      {:ok, reconciliation}
    end
  end

  defp reconcile_blocker_closeout_appender(%Session{} = session) do
    fn repo, work_package_id, attrs ->
      PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, work_package_id, attrs)
    end
  end

  defp maybe_record_reconcile_product_tree_revision(repo, work_request_id, recorded_by, reconciliation) do
    cond do
      reconcile_applied_delivery_closeout?(reconciliation) ->
        record_current_product_tree_revision(repo, work_request_id, "reconcile_work_request", recorded_by)

      reconcile_delivery_closeout_backfill?(reconciliation) ->
        maybe_record_reconcile_product_tree_revision_backfill(repo, work_request_id, recorded_by)

      true ->
        {:ok, nil}
    end
  end

  defp reconcile_applied_delivery_closeout?(%{applied_count: count}) when count > 0, do: true
  defp reconcile_applied_delivery_closeout?(_reconciliation), do: false

  defp reconcile_delivery_closeout_backfill?(%{results: results}) when is_list(results) do
    Enum.any?(results, &reconcile_result_has_delivery_closeout?/1)
  end

  defp reconcile_delivery_closeout_backfill?(_reconciliation), do: false

  defp maybe_record_reconcile_product_tree_revision_backfill(repo, work_request_id, recorded_by) do
    case ProductTree.tree_for_work_request(repo, work_request_id) do
      {:ok, %{latest_revision: nil}} ->
        record_current_product_tree_revision(repo, work_request_id, "reconcile_work_request", recorded_by)

      {:ok, %{"latest_revision" => nil}} ->
        record_current_product_tree_revision(repo, work_request_id, "reconcile_work_request", recorded_by)

      {:ok, _product_tree} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile_result_has_delivery_closeout?(%{reason: "already_closeout", work_package_status: status}) when is_binary(status), do: true
  defp reconcile_result_has_delivery_closeout?(_result), do: false

  defp require_planned_slice_delivery_scope(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, attrs, filters) do
    primary_scope? = WorkRequestScope.primary_work_request_scope?(repo, work_request, filters)

    with :ok <- require_linked_delivery_work_package_scope(repo, work_request, planned_slice, primary_scope?, filters),
         :ok <- require_successor_planned_slice_scope(repo, work_request, attrs) do
      require_successor_work_package_scope(repo, work_request, attrs, primary_scope?, filters)
    end
  end

  defp require_linked_delivery_work_package_scope(
         _repo,
         %WorkRequest{},
         %PlannedSlice{work_package_id: work_package_id},
         _primary_scope?,
         _filters
       )
       when work_package_id in [nil, ""],
       do: :ok

  defp require_linked_delivery_work_package_scope(
         repo,
         %WorkRequest{} = work_request,
         %PlannedSlice{work_package_id: work_package_id} = planned_slice,
         primary_scope?,
         filters
       ) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
      WorkRequestScope.require_scoped_delivery_work_package_visibility(
        work_package,
        work_request,
        planned_slice,
        primary_scope?,
        filters
      )
    end
  end

  defp require_successor_work_package_scope(repo, %WorkRequest{} = work_request, attrs, primary_scope?, filters) do
    case Map.get(attrs, "successor_work_package_id") do
      nil ->
        :ok

      successor_work_package_id ->
        with {:ok, successor_work_package} <- WorkPackageRepository.get(repo, successor_work_package_id),
             {:ok, successor_slice} <-
               scoped_work_request_work_package_planned_slice(repo, work_request.id, successor_work_package_id) do
          WorkRequestScope.require_scoped_delivery_work_package_visibility(
            successor_work_package,
            work_request,
            successor_slice,
            primary_scope?,
            filters
          )
        else
          {:tool_error, reason} -> {:tool_error, reason}
          {:error, :not_found} -> {:tool_error, "successor_work_package_out_of_scope"}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp require_successor_planned_slice_scope(_repo, %WorkRequest{}, %{"outcome" => outcome}) when outcome != "superseded", do: :ok

  defp require_successor_planned_slice_scope(repo, %WorkRequest{} = work_request, attrs) do
    case Map.get(attrs, "successor_planned_slice_id") do
      nil ->
        {:tool_error, "missing_successor_planned_slice_id"}

      successor_planned_slice_id ->
        case WorkRequestScope.scoped_work_request_planned_slice(repo, work_request.id, successor_planned_slice_id) do
          {:ok, successor_slice} -> require_successor_work_package_matches_slice(successor_slice, attrs)
          {:error, :not_found} -> {:tool_error, "successor_planned_slice_out_of_scope"}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp require_successor_work_package_matches_slice(%PlannedSlice{} = successor_slice, attrs) do
    case Map.get(attrs, "successor_work_package_id") do
      nil -> :ok
      successor_work_package_id when successor_work_package_id == successor_slice.work_package_id -> :ok
      _successor_work_package_id -> {:tool_error, "successor_work_package_slice_mismatch"}
    end
  end

  defp scoped_work_request_work_package_planned_slice(repo, work_request_id, work_package_id) do
    case PlannedSliceLinkage.linked_slice_for_work_package(repo, work_request_id, work_package_id) do
      {:ok, %PlannedSlice{} = planned_slice} -> {:ok, planned_slice}
      {:error, :ambiguous_planned_slice_link} -> {:tool_error, "ambiguous_planned_slice_link"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_work_request_planned_slice_runtime_in_transaction(
         repo,
         %Session{} = session,
         %WorkRequest{} = work_request,
         %PlannedSlice{} = planned_slice,
         work_package_id,
         reason,
         delivery_evidence,
         filters
       ) do
    primary_scope? = WorkRequestScope.primary_work_request_scope?(repo, work_request, filters)

    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, _architect_grant} <- WorkRequestScope.require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         :ok <-
           WorkRequestScope.require_scoped_delivery_work_package_visibility(
             work_package,
             work_request,
             planned_slice,
             primary_scope?,
             filters
           ),
         :ok <- require_runtime_cleanup_delivery_state(work_package, delivery_evidence) do
      WorkRequestRuntimeCleanup.cleanup(repo, work_request, planned_slice, work_package, session.assignment,
        reason: reason,
        delivery_evidence: delivery_evidence
      )
    end
  end

  defp require_runtime_cleanup_delivery_state(%WorkPackage{}, %{"outcome" => "superseded"}), do: :ok

  defp require_runtime_cleanup_delivery_state(%WorkPackage{status: status}, %{"outcome" => "abandoned"})
       when status in ["planning", "ready_for_worker"],
       do: :ok

  defp require_runtime_cleanup_delivery_state(%WorkPackage{}, %{"outcome" => "abandoned"}), do: {:tool_error, "work_package_not_abandonable"}

  defp revoke_planned_slice_worker_key_in_transaction(
         repo,
         %Session{} = session,
         %WorkRequest{} = work_request,
         %PlannedSlice{} = planned_slice,
         work_package_id,
         grant_id,
         reason,
         filters
       ) do
    now = DateTime.utc_now(:microsecond)
    primary_scope? = WorkRequestScope.primary_work_request_scope?(repo, work_request, filters)

    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, _architect_grant} <- WorkRequestScope.require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         :ok <- lock_work_package(repo, work_package_id),
         :ok <- lock_access_grant(repo, grant_id),
         {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         :ok <-
           WorkRequestScope.require_scoped_delivery_work_package_visibility(
             work_package,
             work_request,
             planned_slice,
             primary_scope?,
             filters
           ),
         :ok <- PlannedSliceWorkerRevoke.require_revoke_status(work_package),
         {:ok, grant} <- scoped_planned_slice_worker_grant_for_revoke(repo, grant_id, work_package_id, now),
         {:ok, recycled_work_package} <- PlannedSliceWorkerRevoke.update_status(repo, work_package, now),
         {:ok, revoked_grant} <- revoke_live_planned_slice_worker_grant(repo, grant, now),
         {:ok, event} <-
           append_planned_slice_worker_revoke_event(
             repo,
             session,
             work_request,
             planned_slice,
             work_package.status,
             recycled_work_package,
             revoked_grant,
             reason
           ) do
      {:ok,
       planned_slice_worker_revoke_result(
         work_request,
         planned_slice,
         work_package.status,
         recycled_work_package,
         revoked_grant,
         event,
         reason
       )}
    end
  end

  defp scoped_planned_slice_worker_grant_for_revoke(repo, grant_id, work_package_id, %DateTime{} = now) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id),
         :ok <- require_planned_slice_worker_grant_scope(grant, work_package_id),
         :ok <- require_live_planned_slice_worker_grant_for_revoke(grant, now) do
      {:ok, grant}
    end
  end

  defp require_planned_slice_worker_grant_scope(%AccessGrant{work_package_id: work_package_id}, work_package_id), do: :ok
  defp require_planned_slice_worker_grant_scope(%AccessGrant{}, _work_package_id), do: {:tool_error, "worker_grant_out_of_scope"}

  defp require_live_planned_slice_worker_grant_for_revoke(%AccessGrant{grant_role: "worker"} = grant, now) do
    cond do
      grant.provenance == @child_worker_grant_provenance ->
        {:tool_error, "not_planned_slice_worker_grant"}

      not child_worker_grant_capabilities?(grant.capabilities || []) ->
        {:tool_error, "not_planned_slice_worker_grant"}

      match?(%DateTime{}, grant.revoked_at) ->
        {:tool_error, "planned_slice_worker_grant_already_revoked"}

      not live_expires_at?(grant.expires_at, now) ->
        {:tool_error, "planned_slice_worker_grant_expired"}

      true ->
        :ok
    end
  end

  defp require_live_planned_slice_worker_grant_for_revoke(%AccessGrant{}, _now), do: {:tool_error, "not_planned_slice_worker_grant"}

  defp child_worker_grant_capabilities?(capabilities) when is_list(capabilities) do
    Enum.all?(capabilities, &(&1 in @child_worker_capabilities))
  end

  defp child_worker_grant_capabilities?(_capabilities), do: false

  defp revoke_live_planned_slice_worker_grant(repo, %AccessGrant{} = grant, %DateTime{} = now) do
    query =
      from(access_grant in AccessGrant,
        where:
          access_grant.id == ^grant.id and access_grant.work_package_id == ^grant.work_package_id and
            access_grant.grant_role == "worker" and is_nil(access_grant.revoked_at) and
            (is_nil(access_grant.expires_at) or access_grant.expires_at > ^now)
      )

    case repo.update_all(query, set: [revoked_at: now, updated_at: now]) do
      {1, _rows} -> AccessGrantRepository.get(repo, grant.id)
      {0, _rows} -> classify_planned_slice_worker_revoke_miss(repo, grant.id, now)
    end
  end

  defp classify_planned_slice_worker_revoke_miss(repo, grant_id, %DateTime{} = now) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id) do
      case require_live_planned_slice_worker_grant_for_revoke(grant, now) do
        :ok -> {:tool_error, "planned_slice_worker_revoke_conflict"}
        {:tool_error, reason} -> {:tool_error, reason}
      end
    end
  end

  defp append_planned_slice_worker_revoke_event(
         repo,
         %Session{} = session,
         %WorkRequest{} = work_request,
         %PlannedSlice{} = planned_slice,
         previous_work_package_status,
         %WorkPackage{} = work_package,
         %AccessGrant{} = grant,
         reason
       ) do
    payload =
      PlannedSliceWorkerRevoke.payload(
        work_request,
        planned_slice,
        previous_work_package_status,
        work_package,
        grant,
        reason
      )

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, work_package.id, %{
      "summary" => "WorkRequest planned-slice worker grant revoked for cleanup",
      "body" => "Cleanup reason: #{redacted_child_worker_revoke_reason(reason)}; WorkRequest: #{work_request.id}; planned slice: #{planned_slice.id}",
      "status" => "planned_slice_worker_key_revoked",
      "idempotency_key" => ProgressEvents.metadata_idempotency_key(payload),
      "payload" => payload
    })
  end

  defp planned_slice_worker_revoke_result(
         %WorkRequest{} = work_request,
         %PlannedSlice{} = planned_slice,
         previous_work_package_status,
         %WorkPackage{} = work_package,
         %AccessGrant{} = grant,
         %ProgressEvent{} = event,
         _reason
       ) do
    reason_codes = PlannedSliceWorkerRevoke.reason_codes(previous_work_package_status, work_package.status)

    %{
      "planned_slice" => %{"id" => planned_slice.id, "work_request_id" => work_request.id, "status" => planned_slice.status},
      "work_package" => Payloads.work_package_payload(work_package),
      "revoked_worker_grant" => %{"id" => grant.id, "work_package_id" => grant.work_package_id},
      "closeout_affordance" => %{
        "status" => "revoked",
        "previous_work_package_status" => previous_work_package_status,
        "work_package_status" => work_package.status,
        "reason_codes" => reason_codes
      },
      "audit_event" => ProgressEvents.payload(event),
      "next_action" => "retry_record_planned_slice_delivery"
    }
  end

  defp redacted_child_worker_revoke_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> Redactor.redact_text()
  end

  defp mutate_product_tree(repo, work_request_id, tool, created_by, mutation_fun) do
    run_architect_transaction(repo, fn ->
      with {:ok, result} <- mutation_fun.(),
           {:ok, _revision} <- record_current_product_tree_revision(repo, work_request_id, tool, created_by) do
        {:ok, result}
      end
    end)
  end

  defp record_current_product_tree_revision(repo, work_request_id, tool, created_by) do
    case Dashboard.work_request_detail(repo, work_request_id) do
      {:ok, detail} ->
        record_product_tree_revision(repo, work_request_id, tool, created_by, detail)

      {:error, reason} = error ->
        if missing_product_tree_schema_error?(reason), do: {:ok, nil}, else: error
    end
  end

  defp record_product_tree_revision(repo, work_request_id, tool, created_by, detail) do
    snapshot = product_tree_revision_snapshot(detail.product_tree)
    tree = ProductTree.tree_for_work_request(repo, work_request_id)

    if match?({:ok, %{latest_revision: %{tree_snapshot: ^snapshot}}}, tree) do
      {:ok, nil}
    else
      insert_product_tree_revision(repo, work_request_id, tool, created_by, snapshot)
    end
  end

  defp insert_product_tree_revision(repo, work_request_id, tool, created_by, snapshot) do
    case ProductTree.record_revision(repo, work_request_id, %{
           "reason" => product_tree_revision_reason(tool),
           "created_by" => created_by,
           "tree_snapshot" => snapshot
         }) do
      {:error, reason} = error ->
        if missing_product_tree_schema_error?(reason), do: {:ok, nil}, else: error

      result ->
        result
    end
  end

  defp missing_product_tree_schema_error?({:storage_failed, message}) when is_binary(message) do
    message
    |> String.downcase()
    |> String.contains?("no such table: sympp_product_tree_")
  end

  defp missing_product_tree_schema_error?(_reason), do: false

  defp product_tree_revision_snapshot(product_tree) do
    product_tree
    |> Payloads.json_safe_payload()
    |> Map.delete("latest_revision")
  end

  defp product_tree_revision_reason("record_planned_slice_delivery"), do: "Planned slice delivery recorded in product tree through MCP."
  defp product_tree_revision_reason("reconcile_work_request"), do: "Planned slice delivery reconciled in product tree through MCP."

  defp run_architect_transaction(repo, fun) do
    case repo.transaction(fn -> rollback_architect_transaction_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_architect_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_architect_transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})
  defp rollback_architect_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp lock_access_grant(repo, grant_id) do
    query = from(access_grant in AccessGrant, where: access_grant.id == ^grant_id)

    case repo.update_all(query, set: [id: grant_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :phase_scope_not_available}
    end
  end

  defp require_architect_capability(%{capabilities: capabilities}, capability) when is_list(capabilities) do
    if capability in capabilities do
      :ok
    else
      {:error, :insufficient_capability}
    end
  end

  defp require_architect_capability(_assignment, _capability), do: {:error, :insufficient_capability}

  defp session_claimed_by(%Session{assignment: %{claimed_by: claimed_by}}) when is_binary(claimed_by) do
    case String.trim(claimed_by) do
      "" -> "architect"
      trimmed -> trimmed
    end
  end

  defp session_claimed_by(%Session{}), do: "architect"

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp not_found_error(tool) do
    {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}
  end

  defp architect_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp architect_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:expired, resource), do: auth_error({:unauthorized, :expired}, resource)
  defp architect_error(:assignment_revoked, resource), do: auth_error({:unauthorized, :revoked}, resource)
  defp architect_error(:architect_grant_required, resource), do: auth_error({:unauthorized, :architect_grant_required}, resource)
  defp architect_error(:insufficient_capability, resource), do: auth_error({:unauthorized, :insufficient_capability}, resource)
  defp architect_error({:authorization_policy_denied, %Decision{} = decision}, resource), do: MCPError.from_decision(decision, resource)
  defp architect_error({:authorization_policy_denied, code, message, data}, _resource), do: {:error, code, message, data}
  defp architect_error(:phase_scope_not_available, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:phase_scope_not_available, _missing_evidence}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:ambiguous_phase_scope, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:work_request_terminal, _terminal_state}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp architect_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp invalid_params_error(tool, {:blocker_closeout_required, blockers}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "blocker_closeout_required",
       "reason_code" => "blocker_closeout_required",
       "message" => "Active blockers exist in this finish scope. Pass blocker_closeout with decision resolved or still_active.",
       "active_blockers" => blockers
     }}
  end

  defp invalid_params_error(tool, {:blocker_closeout_scope_mismatch, active_ids, requested_ids}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "blocker_closeout_scope_mismatch",
       "reason_code" => "blocker_closeout_scope_mismatch",
       "active_blocker_ids" => active_ids,
       "requested_blocker_ids" => requested_ids
     }}
  end

  defp invalid_params_error(tool, reason) do
    {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}
  end

  defp changeset_invalid_params_error(tool, reason, %Ecto.Changeset{} = changeset) do
    data =
      case changeset_validation_errors(changeset) do
        [] -> %{"tool" => tool, "reason" => reason_text(reason)}
        errors -> %{"tool" => tool, "reason" => reason_text(reason), "validation_errors" => errors}
      end

    {:error, -32_602, "Invalid params", data}
  end

  defp changeset_validation_errors(%Ecto.Changeset{errors: errors}) do
    Enum.map(errors, fn {field, error} -> changeset_validation_error(field, error) end)
  end

  defp changeset_validation_error(field, {message, opts}) do
    field = Atom.to_string(field)

    %{
      "field" => field,
      "message" => changeset_validation_message(message, opts),
      "reason" => changeset_validation_reason(opts)
    }
    |> maybe_put_allowed_values(opts)
  end

  defp changeset_validation_message(message, opts) do
    Regex.replace(~r/%{(count|number)}/, message, fn _match, key ->
      opts
      |> Keyword.get(changeset_message_key(key))
      |> to_string()
    end)
  end

  defp changeset_message_key("count"), do: :count
  defp changeset_message_key("number"), do: :number

  defp changeset_validation_reason(opts) do
    case Keyword.get(opts, :validation) do
      :required -> "required"
      :inclusion -> "invalid_value"
      :number -> "invalid_number"
      validation when is_atom(validation) -> Atom.to_string(validation)
      _validation -> "invalid"
    end
  end

  defp maybe_put_allowed_values(detail, opts) do
    case Keyword.get(opts, :enum) do
      values when is_list(values) -> Map.put(detail, "allowed_values", Enum.map(values, &reason_text/1))
      _values -> detail
    end
  end

  defp auth_error(:unauthorized, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}
  end

  defp auth_error({:unauthorized, reason}, resource) do
    {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}
  end

  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)

  defp auth_error(:forbidden, resource) do
    {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}
  end

  defp service_error(_reason, resource) do
    {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)

  defp live_expires_at?(nil, %DateTime{}), do: true
  defp live_expires_at?(%DateTime{} = expires_at, %DateTime{} = now), do: DateTime.compare(expires_at, now) == :gt
end
