defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ArchitectDeliveryTools do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_boolean: 3,
      optional_object_argument: 2,
      optional_positive_integer_argument: 2,
      optional_string_argument: 2,
      optional_string_argument: 3,
      optional_string_list_argument: 2,
      required_argument: 2,
      required_object: 2
    ]

  import SymphonyElixir.SymphonyPlusPlus.MCP.Payloads,
    only: [
      child_work_package_payload: 1,
      json_safe_payload: 1,
      work_package_payload: 1
    ]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.MetadataProjection
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequestProgress

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Auth,
    Config,
    CurrentWorkRequest,
    ErrorDetails,
    ProgressEvents,
    Session,
    ToolArguments,
    ToolCatalog,
    ToolResult,
    WorkPackageWorkerRevoke,
    WorkRequestPayloads,
    WorkRequestScope
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryCloseout
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryReconciler
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.RuntimeCleanup, as: WorkRequestRuntimeCleanup
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @blocker_closeout_decisions ToolCatalog.blocker_closeout_decisions()
  @child_worker_capabilities ["worker:claim", "worker:lifecycle.transition"]
  @child_worker_grant_provenance "child_worker_delegation"

  @typep mcp_tool_result :: {:ok, map()} | {:error, integer(), String.t(), map()}
  @typep blocker_closeout_plan ::
           :not_needed
           | %{
               required(:active_blockers) => list(),
               required(:closeout) => map(),
               required(:tool) => String.t()
             }

  @spec call(String.t(), Config.t(), Session.t() | nil, map()) :: mcp_tool_result()
  def call("reconcile_work_request", %Config{} = config, session, arguments) do
    with {:ok, live_session} <- architect_session(config.repo, session),
         {:ok, apply?} <- optional_boolean(arguments, "apply", false),
         :ok <- require_architect_capability(live_session, reconcile_work_request_capability(apply?)),
         {:ok, arguments} <- validate_arguments(arguments, "reconcile_work_request"),
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
         {:ok, work_packages} <- WorkRequestService.list_work_packages(config.repo, work_request_id),
         {visible_work_package_ids, work_package_contexts} <-
           WorkRequestScope.visible_delivery_board_work_package_contexts(
             config.repo,
             work_request,
             work_packages,
             filters
           ),
         {:ok, reconciliation} <-
           reconcile_work_request(config.repo, live_session, work_request_id, apply?, recorded_by,
             mode: reconcile_work_request_mode(apply?),
             work_request: work_request,
             work_packages: work_packages,
             visible_work_package_ids: visible_work_package_ids,
             work_package_contexts: work_package_contexts
           ) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
         "reconciliation" => reconciliation_payload(reconciliation),
         "delivery_board" => WorkRequestPayloads.delivery_board(Map.fetch!(reconciliation, :delivery_board)),
         "scope" => scope
       })}
    else
      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => "reconcile_work_request", "reason" => reason}}

      {:error, :not_found} ->
        not_found_error("reconcile_work_request")

      {:error, reason} ->
        architect_error(reason, "reconcile_work_request")
    end
  end

  def call("record_work_package_delivery", %Config{} = config, session, arguments) do
    with {:ok, live_session} <- architect_session(config.repo, session, "write:work_request"),
         {:ok, arguments} <- validate_arguments(arguments, "record_work_package_delivery"),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, live_session),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, outcome} <- required_work_package_delivery_outcome(arguments),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, recorded_by} <- optional_string_argument(arguments, "recorded_by", session_claimed_by(live_session)),
         {:ok, attrs} <- work_package_delivery_attrs(arguments, outcome, idempotency_key, recorded_by),
         {:ok, work_request, work_package, filters, scope} <-
           WorkRequestScope.authorized_work_package_scope(
             config.repo,
             live_session,
             work_request_id,
             work_package_id,
             :delivery_closeout_record,
             "record_work_package_delivery"
           ),
         :ok <- require_work_package_delivery_scope(config.repo, work_request, work_package, attrs, filters),
         {:ok, {delivery, cleanup_work_package, closeout_context}} <-
           mutate_product_tree(
             config.repo,
             work_request_id,
             "record_work_package_delivery",
             recorded_by,
             fn ->
               DeliveryCloseout.record_in_transaction(
                 config.repo,
                 work_request_id,
                 work_package_id,
                 attrs
               )
             end
           ),
         _delivery_broadcast_result <- DashboardPubSub.broadcast_changed(),
         :ok <-
           DeliveryCloseout.cleanup_after_commit(
             config.repo,
             cleanup_work_package,
             delivery,
             closeout_context
           ),
         _cleanup_broadcast_result <- DashboardPubSub.broadcast_changed(),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(config.repo, work_request_id),
         {:ok, delivery_board} <-
           WorkRequestScope.scoped_delivery_board(config.repo, work_request, work_packages, filters) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
         "work_package_delivery" => WorkRequestPayloads.work_package_delivery(delivery),
         "delivery_board" => WorkRequestPayloads.delivery_board(delivery_board),
         "scope" => scope
       })}
    else
      {:tool_error, reason} -> invalid_params_error("record_work_package_delivery", reason)
      {:error, :not_found} -> not_found_error("record_work_package_delivery")
      {:error, reason} -> record_work_package_delivery_error(reason)
    end
  end

  def call("accept_review_rework", %Config{} = config, session, arguments) do
    with {:ok, live_session} <- architect_session(config.repo, session, "write:work_request"),
         {:ok, arguments} <- validate_arguments(arguments, "accept_review_rework"),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, live_session),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, evidence} <- accepted_review_rework_evidence(arguments),
         {:ok, work_request, work_package, filters, scope} <-
           WorkRequestScope.authorized_work_package_scope(
             config.repo,
             live_session,
             work_request_id,
             work_package_id,
             :work_package_repair_state,
             "accept_review_rework"
           ),
         {:ok, result} <-
           run_architect_transaction(config.repo, fn ->
             accept_review_rework_in_transaction(
               config.repo,
               live_session,
               work_request,
               work_package,
               filters,
               evidence,
               "accept_review_rework:#{work_package_id}:#{String.trim(idempotency_key)}"
             )
           end) do
      {:ok,
       ToolResult.tool_result(%{
         "work_package" => work_package_payload(result.work_package),
         "accepted_review_rework" => ProgressEvents.payload(result.event),
         "scope" => scope
       })}
    else
      {:tool_error, reason} -> invalid_params_error("accept_review_rework", reason)
      {:error, :not_found} -> not_found_error("accept_review_rework")
      {:error, reason} -> architect_error(reason, "accept_review_rework")
    end
  end

  def call("cleanup_work_request_work_package_runtime", %Config{} = config, session, arguments) do
    with {:ok, live_session} <- architect_session(config.repo, session, "write:work_request"),
         {:ok, arguments} <- validate_arguments(arguments, "cleanup_work_request_work_package_runtime"),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, live_session),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, outcome} <- required_runtime_cleanup_delivery_outcome(arguments),
         {:ok, reason} <- required_argument(arguments, "reason"),
         {:ok, delivery_evidence} <-
           runtime_cleanup_delivery_evidence_attrs(arguments, outcome, work_request_id, work_package_id),
         {:ok, work_request, work_package, filters, scope} <-
           WorkRequestScope.authorized_work_package_scope(
             config.repo,
             live_session,
             work_request_id,
             work_package_id,
             :work_package_repair_state,
             "cleanup_work_request_work_package_runtime"
           ),
         :ok <-
           require_work_package_delivery_scope(config.repo, work_request, work_package, delivery_evidence, filters),
         {:ok, cleanup} <-
           run_architect_transaction(config.repo, fn ->
             cleanup_work_request_work_package_runtime_in_transaction(
               config.repo,
               live_session,
               work_request,
               work_package,
               work_package_id,
               reason,
               delivery_evidence,
               filters
             )
           end) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
         "work_package" => child_work_package_payload(Map.fetch!(cleanup, :work_package)),
         "runtime_cleanup" => Map.fetch!(cleanup, :runtime_cleanup),
         "audit_event" => ProgressEvents.payload(Map.fetch!(cleanup, :audit_event)),
         "scope" => scope
       })}
    else
      {:tool_error, reason} ->
        invalid_params_error("cleanup_work_request_work_package_runtime", reason)

      {:error, :not_found} ->
        not_found_error("cleanup_work_request_work_package_runtime")

      {:error, reason} ->
        work_request_runtime_cleanup_error(reason)
    end
  end

  def call("revoke_work_package_worker_key", %Config{} = config, session, arguments) do
    with {:ok, live_session} <- architect_session(config.repo, session, "write:work_request"),
         {:ok, arguments} <- validate_arguments(arguments, "revoke_work_package_worker_key"),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, live_session),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, grant_id} <- required_argument(arguments, "grant_id"),
         {:ok, reason} <- required_argument(arguments, "reason"),
         {:ok, work_request, work_package, filters, scope} <-
           WorkRequestScope.authorized_work_package_scope(
             config.repo,
             live_session,
             work_request_id,
             work_package_id,
             :work_package_repair_state,
             "revoke_work_package_worker_key"
           ),
         {:ok, payload} <-
           run_architect_transaction(config.repo, fn ->
             revoke_work_package_worker_key_in_transaction(
               config.repo,
               live_session,
               work_request,
               work_package,
               work_package_id,
               grant_id,
               reason,
               filters
             )
           end) do
      {:ok, ToolResult.tool_result(Map.put(payload, "scope", scope))}
    else
      {:tool_error, reason} ->
        work_package_worker_revoke_tool_error(reason)

      {:error, :not_found} ->
        not_found_error("revoke_work_package_worker_key")

      {:error, reason} ->
        architect_error(reason, "revoke_work_package_worker_key")
    end
  end

  @spec cleanup_worktree_runtime(module(), Session.t(), WorkPackage.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def cleanup_worktree_runtime(repo, %Session{} = session, %WorkPackage{} = work_package) do
    run_architect_transaction(repo, fn ->
      cleanup_worktree_runtime_in_transaction(repo, session, work_package.id)
    end)
  end

  @spec prepare_scoped_blocker_closeout(module(), Session.t(), [String.t()], map(), String.t()) ::
          {:ok, blocker_closeout_plan()} | {:tool_error, term()} | {:error, term()}
  def prepare_scoped_blocker_closeout(repo, %Session{}, work_package_ids, arguments, tool) do
    with {:ok, closeout} <- optional_blocker_closeout_argument(arguments),
         {:ok, active_blockers} <- active_blockers_for_work_packages(repo, work_package_ids) do
      cond do
        active_blockers == [] ->
          {:ok, :not_needed}

        is_nil(closeout) ->
          {:tool_error, {:blocker_closeout_required, active_blocker_payloads(active_blockers)}}

        true ->
          prepare_active_blocker_closeout(active_blockers, closeout, tool)
      end
    end
  end

  @spec apply_prepared_blocker_closeout(module(), Session.t(), blocker_closeout_plan()) ::
          {:ok, map()} | {:tool_error, term()} | {:error, term()}
  def apply_prepared_blocker_closeout(_repo, %Session{}, :not_needed), do: {:ok, blocker_closeout_not_needed()}

  def apply_prepared_blocker_closeout(repo, %Session{} = session, %{
        active_blockers: active_blockers,
        closeout: closeout,
        tool: tool
      }) do
    apply_blocker_closeout_decision(repo, session, active_blockers, closeout, tool)
  end

  defp required_work_package_delivery_outcome(arguments) do
    with {:ok, outcome} <- required_argument(arguments, "outcome") do
      if outcome in WorkPackageDelivery.outcomes() do
        {:ok, outcome}
      else
        {:tool_error, {:invalid_enum, "outcome", WorkPackageDelivery.outcomes()}}
      end
    end
  end

  defp accepted_review_rework_evidence(arguments) do
    with {:ok, evidence} <- required_object(arguments, "evidence"),
         {:ok, provider} <- required_argument(evidence, "provider"),
         {:ok, reference} <- required_argument(evidence, "reference"),
         {:ok, head_sha} <- required_argument(evidence, "head_sha"),
         {:ok, finding} <- required_argument(evidence, "finding") do
      normalized = %{
        "provider" => provider |> String.trim() |> Redactor.redact_text(),
        "reference" => reference |> String.trim() |> Redactor.redact_text(),
        "head_sha" => head_sha |> String.trim() |> String.downcase(),
        "finding" => finding |> String.trim() |> Redactor.redact_text()
      }

      if Enum.all?(Map.values(normalized), &filled_string?/1),
        do: {:ok, normalized},
        else: {:tool_error, "empty_accepted_review_rework_evidence"}
    end
  end

  defp required_runtime_cleanup_delivery_outcome(arguments) do
    allowed_outcomes = ["superseded", "abandoned"]

    with {:ok, outcome} <- required_argument(arguments, "outcome") do
      if outcome in allowed_outcomes do
        {:ok, outcome}
      else
        {:tool_error, {:invalid_enum, "outcome", allowed_outcomes}}
      end
    end
  end

  defp runtime_cleanup_delivery_evidence_attrs(arguments, outcome, work_request_id, work_package_id) do
    with {:ok, successor_work_package_id} <- optional_string_argument(arguments, "successor_work_package_id"),
         {:ok, superseded_reason} <- optional_string_argument(arguments, "superseded_reason"),
         {:ok, abandoned_rationale} <- optional_string_argument(arguments, "abandoned_rationale") do
      attrs =
        %{
          "work_request_id" => work_request_id,
          "work_package_id" => work_package_id,
          "outcome" => outcome,
          "idempotency_key" => "runtime-cleanup-evidence"
        }
        |> optional_put("successor_work_package_id", successor_work_package_id)
        |> optional_put("superseded_reason", superseded_reason)
        |> optional_put("abandoned_rationale", abandoned_rationale)

      validate_runtime_cleanup_delivery_evidence(attrs)
    end
  end

  defp validate_runtime_cleanup_delivery_evidence(attrs) do
    case attrs |> WorkPackageDelivery.create_changeset() |> Ecto.Changeset.apply_action(:insert) do
      {:ok, _delivery} -> {:ok, attrs}
      {:error, changeset} -> {:tool_error, {:invalid_changeset, "invalid_delivery_evidence", changeset}}
    end
  end

  defp work_package_delivery_attrs(arguments, outcome, idempotency_key, recorded_by) do
    with {:ok, evidence} <- required_object(arguments, "evidence"),
         {:ok, evidence_attrs} <- work_package_delivery_evidence_attrs(evidence, outcome) do
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

  defp work_package_delivery_evidence_attrs(evidence, outcome) do
    case Map.keys(evidence) do
      [^outcome] ->
        with {:ok, typed_evidence} <- required_object(evidence, outcome) do
          work_package_delivery_typed_evidence_attrs(outcome, typed_evidence)
        end

      [] ->
        work_package_delivery_typed_evidence_attrs(outcome, %{})

      _keys ->
        {:tool_error, "conflicting_delivery_evidence"}
    end
  end

  defp work_package_delivery_typed_evidence_attrs(outcome, evidence) do
    case WorkPackageDelivery.validate_evidence(outcome, evidence) do
      :ok ->
        collect_work_package_delivery_evidence_attrs(
          evidence,
          WorkPackageDelivery.evidence_field_specs(outcome)
        )

      {:error, details} ->
        {:tool_error, {:invalid_evidence, details}}
    end
  end

  defp collect_work_package_delivery_evidence_attrs(evidence, field_specs) do
    Enum.reduce_while(field_specs, {:ok, %{}}, fn %{name: field, type: type}, {:ok, attrs} ->
      case work_package_delivery_evidence_field(evidence, field, type) do
        {:ok, value} -> {:cont, {:ok, optional_put(attrs, field, value)}}
        {:tool_error, reason} -> {:halt, {:tool_error, reason}}
      end
    end)
  end

  defp work_package_delivery_evidence_field(evidence, field, :string), do: optional_string_argument(evidence, field)

  defp work_package_delivery_evidence_field(evidence, field, :positive_integer),
    do: optional_positive_integer_argument(evidence, field)

  defp prepare_active_blocker_closeout(active_blockers, closeout, tool) do
    with :ok <- require_blocker_closeout_covers_active_blockers(active_blockers, closeout.blocker_ids) do
      {:ok, %{active_blockers: active_blockers, closeout: closeout, tool: tool}}
    end
  end

  defp optional_blocker_closeout_argument(arguments) do
    with {:ok, closeout} <- optional_object_argument(arguments, "blocker_closeout") do
      normalize_blocker_closeout(closeout)
    end
  end

  defp normalize_blocker_closeout(nil), do: {:ok, nil}

  defp normalize_blocker_closeout(closeout) when is_map(closeout) do
    with {:ok, decision} <- required_argument(closeout, "decision"),
         :ok <- require_blocker_closeout_decision(decision),
         {:ok, blocker_ids} <- optional_string_list_argument(closeout, "blocker_ids"),
         {:ok, resolution} <- optional_string_argument(closeout, "resolution"),
         {:ok, summary} <- optional_string_argument(closeout, "summary"),
         :ok <- require_blocker_closeout_resolution(decision, resolution) do
      {:ok, %{decision: decision, blocker_ids: blocker_ids, resolution: resolution, summary: summary}}
    end
  end

  defp require_blocker_closeout_decision(decision),
    do: if(decision in @blocker_closeout_decisions, do: :ok, else: {:tool_error, "invalid_blocker_closeout_decision"})

  defp require_blocker_closeout_resolution("resolved", resolution) when is_binary(resolution), do: :ok

  defp require_blocker_closeout_resolution("resolved", _resolution),
    do: {:tool_error, "missing_blocker_closeout_resolution"}

  defp require_blocker_closeout_resolution("still_active", _resolution), do: :ok

  defp apply_blocker_closeout_decision(repo, %Session{} = session, active_blockers, closeout, tool) do
    with :ok <- require_blocker_closeout_covers_active_blockers(active_blockers, closeout.blocker_ids) do
      case closeout.decision do
        "resolved" -> resolve_active_blockers(repo, session, active_blockers, closeout, tool)
        "still_active" -> preserve_active_blockers(repo, session, active_blockers, closeout, tool)
      end
    end
  end

  defp require_blocker_closeout_covers_active_blockers(_active_blockers, []), do: :ok

  defp require_blocker_closeout_covers_active_blockers(active_blockers, blocker_ids) do
    active_ids =
      active_blockers
      |> Enum.map(& &1.id)
      |> Enum.sort()

    requested_ids = Enum.sort(blocker_ids)

    if requested_ids == active_ids do
      :ok
    else
      {:tool_error, {:blocker_closeout_scope_mismatch, active_ids, requested_ids}}
    end
  end

  defp resolve_active_blockers(repo, %Session{} = session, active_blockers, closeout, tool) do
    with {:ok, events} <-
           append_blocker_closeout_events(active_blockers, fn blocker ->
             append_blocker_closeout_resolution(repo, session, blocker, closeout, tool)
           end) do
      {:ok,
       %{
         "decision" => "resolved",
         "active_blockers_before" => active_blocker_payloads(active_blockers),
         "resolved_blocker_ids" => Enum.map(active_blockers, & &1.id),
         "progress_event_ids" => events |> Enum.reverse() |> Enum.map(& &1.id)
       }}
    end
  end

  defp preserve_active_blockers(repo, %Session{} = session, active_blockers, closeout, tool) do
    with {:ok, events} <-
           append_blocker_closeout_events(active_blockers, fn blocker ->
             append_blocker_closeout_preservation(repo, session, blocker, closeout, tool)
           end) do
      {:ok,
       %{
         "decision" => "still_active",
         "active_blockers" => active_blocker_payloads(active_blockers),
         "progress_event_ids" => events |> Enum.reverse() |> Enum.map(& &1.id)
       }}
    end
  end

  defp append_blocker_closeout_events(active_blockers, append_fun) do
    Enum.reduce_while(active_blockers, {:ok, []}, fn blocker, {:ok, events} ->
      append_blocker_closeout_event(append_fun, blocker, events)
    end)
  end

  defp append_blocker_closeout_event(append_fun, blocker, events) do
    case append_fun.(blocker) do
      {:ok, event} -> {:cont, {:ok, [event | events]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp append_blocker_closeout_resolution(repo, %Session{} = session, blocker, closeout, tool) do
    PlanningRepository.append_audit_progress_event_for_work_package(
      repo,
      session.assignment,
      blocker.work_package_id,
      %{
        "summary" => closeout.summary || "Resolved blocker during #{tool}",
        "body" => closeout.resolution,
        "status" => "resolved",
        "idempotency_key" => blocker_closeout_idempotency_key(tool, blocker, "resolved"),
        "payload" => %{
          "type" => "blocker",
          "source_tool" => "resolve_blocker",
          "blocker_id" => blocker.id,
          "resolution" => closeout.resolution,
          "active" => false,
          "closeout_tool" => tool
        }
      }
    )
  end

  defp append_blocker_closeout_preservation(repo, %Session{} = session, blocker, closeout, tool) do
    PlanningRepository.append_audit_progress_event_for_work_package(
      repo,
      session.assignment,
      blocker.work_package_id,
      %{
        "summary" => closeout.summary || "Preserved active blocker during #{tool}",
        "body" => closeout.resolution || blocker.body || blocker.summary,
        "status" => "blocked",
        "idempotency_key" => blocker_closeout_idempotency_key(tool, blocker, "still_active"),
        "payload" => %{
          "type" => "blocker_closeout_decision",
          "source_tool" => tool,
          "blocker_id" => blocker.id,
          "decision" => "still_active"
        }
      }
    )
  end

  defp blocker_closeout_idempotency_key(tool, blocker, decision) do
    ["blocker_closeout", tool, blocker.work_package_id, blocker.id, blocker.event_id, decision]
    |> Enum.join(":")
  end

  defp active_blockers_for_work_packages(repo, work_package_ids) do
    work_package_ids =
      work_package_ids
      |> Enum.filter(&filled_string?/1)
      |> Enum.uniq()

    Enum.reduce_while(work_package_ids, {:ok, []}, fn work_package_id, {:ok, blockers} ->
      case active_blockers_for_work_package(repo, work_package_id) do
        {:ok, package_blockers} -> {:cont, {:ok, blockers ++ package_blockers}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp active_blockers_for_work_package(repo, work_package_id) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package_id) do
      blockers =
        progress_events
        |> BlockerProjection.blockers()
        |> Enum.filter(& &1.active)
        |> Enum.map(&Map.put(&1, :work_package_id, work_package_id))

      {:ok, blockers}
    end
  end

  defp active_blocker_payloads(blockers), do: Enum.map(blockers, &active_blocker_payload/1)

  defp active_blocker_payload(blocker) do
    %{
      "blocker_id" => blocker.id,
      "work_package_id" => blocker.work_package_id,
      "summary" => blocker.summary,
      "body" => blocker.body,
      "status" => blocker.status,
      "updated_at" => blocker.updated_at
    }
  end

  defp blocker_closeout_not_needed, do: %{"decision" => "none", "active_blockers" => []}

  defp reconcile_work_request_action(true), do: :delivery_reconcile_apply
  defp reconcile_work_request_action(false), do: :delivery_reconcile_dry_run

  defp validate_arguments(arguments, tool) do
    case ToolArguments.architect_tool_arguments(%{"arguments" => arguments}, tool) do
      {:ok, arguments} -> {:ok, arguments}
      {:error, _code, _message, %{"reason" => reason}} -> {:tool_error, reason}
    end
  end

  defp architect_session(repo, session, capability) do
    with {:ok, session} <- architect_session(repo, session),
         :ok <- require_architect_capability(session, capability) do
      {:ok, session}
    end
  end

  defp architect_session(repo, session) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_architect_assignment(session.assignment) do
      {:ok, session}
    end
  end

  defp require_architect_capability(%Session{} = session, capability) do
    if capability in List.wrap(session.assignment.capabilities), do: :ok, else: {:error, :insufficient_capability}
  end

  defp require_architect_assignment(%{grant_role: "architect"}), do: :ok
  defp require_architect_assignment(_assignment), do: {:error, :architect_grant_required}

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

  defp record_reconcile_product_tree_revision_after_apply(repo, work_request_id, recorded_by, reconciliation) do
    with {:ok, _revision} <-
           maybe_record_reconcile_product_tree_revision(repo, work_request_id, recorded_by, reconciliation) do
      {:ok, reconciliation}
    end
  end

  defp reconcile_blocker_closeout_appender(%Session{} = session) do
    fn repo, work_package_id, attrs ->
      PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, work_package_id, attrs)
    end
  end

  defp maybe_record_reconcile_product_tree_revision(repo, work_request_id, recorded_by, reconciliation) do
    if reconcile_product_tree_revision_required?(reconciliation) do
      record_current_product_tree_revision(repo, work_request_id, "reconcile_work_request", recorded_by)
    else
      {:ok, nil}
    end
  end

  defp reconcile_product_tree_revision_required?(%{applied_count: count}) when count > 0, do: true

  defp reconcile_product_tree_revision_required?(%{results: results}) when is_list(results) do
    Enum.any?(results, &reconcile_result_has_delivery_closeout?/1)
  end

  defp reconcile_result_has_delivery_closeout?(%{reason: "already_closeout", work_package_status: status})
       when is_binary(status),
       do: true

  defp reconcile_result_has_delivery_closeout?(_result), do: false

  defp require_work_package_delivery_scope(
         repo,
         %WorkRequest{} = work_request,
         %WorkPackage{} = work_package,
         attrs,
         filters
       ) do
    primary_scope? = WorkRequestScope.primary_work_request_scope?(repo, work_request, filters)

    with :ok <-
           WorkRequestScope.require_scoped_delivery_work_package_visibility(
             work_package,
             work_request,
             work_package,
             primary_scope?,
             filters
           ) do
      require_successor_work_package_scope(repo, work_request, attrs, primary_scope?, filters)
    end
  end

  defp require_successor_work_package_scope(repo, %WorkRequest{} = work_request, attrs, primary_scope?, filters) do
    case Map.get(attrs, "successor_work_package_id") do
      nil ->
        :ok

      successor_work_package_id ->
        with {:ok, successor_work_package} <- WorkPackageRepository.get(repo, successor_work_package_id),
             {:ok, successor_slice} <-
               scoped_work_request_work_package_work_package(repo, work_request.id, successor_work_package_id) do
          WorkRequestScope.require_scoped_delivery_work_package_visibility(
            successor_work_package,
            work_request,
            successor_slice,
            primary_scope?,
            filters
          )
        else
          {:error, :not_found} -> {:tool_error, "successor_work_package_out_of_scope"}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp scoped_work_request_work_package_work_package(repo, work_request_id, work_package_id) do
    WorkRequestService.get_work_package(repo, work_request_id, work_package_id)
  end

  defp accept_review_rework_in_transaction(
         repo,
         %Session{} = session,
         %WorkRequest{} = work_request,
         %WorkPackage{} = scoped_work_package,
         filters,
         evidence,
         idempotency_key
       ) do
    primary_scope? = WorkRequestScope.primary_work_request_scope?(repo, work_request, filters)

    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, _architect_grant} <- WorkRequestScope.require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         :ok <- lock_work_package(repo, scoped_work_package.id),
         {:ok, work_package} <- WorkPackageRepository.get(repo, scoped_work_package.id),
         :ok <-
           WorkRequestScope.require_scoped_delivery_work_package_visibility(
             work_package,
             work_request,
             work_package,
             primary_scope?,
             filters
           ),
         {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package.id) do
      case Enum.find(progress_events, &(&1.idempotency_key == idempotency_key)) do
        %ProgressEvent{} = event ->
          replay_accepted_review_rework(work_package, event, work_request.id, evidence)

        nil ->
          append_accepted_review_rework(
            repo,
            session,
            work_request,
            work_package,
            progress_events,
            evidence,
            idempotency_key
          )
      end
    end
  end

  defp append_accepted_review_rework(
         repo,
         session,
         work_request,
         work_package,
         progress_events,
         evidence,
         idempotency_key
       ) do
    with :ok <- require_accepted_review_rework_status(work_package),
         {:ok, head_sha, pr} <- current_accepted_review_rework_pr(work_package, progress_events, evidence),
         payload =
           evidence
           |> Map.put("type", "accepted_review_rework")
           |> Map.put("source_tool", "accept_review_rework")
           |> Map.put("work_request_id", work_request.id)
           |> Map.put("work_package_id", work_package.id)
           |> Map.put("head_sha", head_sha)
           |> Map.put("pr", pr),
         {:ok, reopened} <- WorkPackageRepository.update_status(repo, work_package.id, "ready_for_merge", "active"),
         {:ok, event} <-
           PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, work_package.id, %{
             "summary" => "Accepted verified review finding for rework",
             "status" => "accepted_review_rework",
             "idempotency_key" => idempotency_key,
             "payload" => payload
           }) do
      {:ok, %{work_package: reopened, event: event}}
    end
  end

  defp replay_accepted_review_rework(work_package, %ProgressEvent{payload: payload} = event, work_request_id, evidence) do
    expected =
      evidence
      |> Map.take(["provider", "reference", "head_sha", "finding"])
      |> Map.put("type", "accepted_review_rework")
      |> Map.put("source_tool", "accept_review_rework")
      |> Map.put("work_request_id", work_request_id)
      |> Map.put("work_package_id", work_package.id)

    if is_map(payload) and Map.take(payload, Map.keys(expected)) == expected,
      do: {:ok, %{work_package: work_package, event: event}},
      else: {:tool_error, "idempotency_conflict"}
  end

  defp require_accepted_review_rework_status(%WorkPackage{kind: "phase_child"}),
    do: {:tool_error, "phase_child_rework_not_allowed"}

  defp require_accepted_review_rework_status(%WorkPackage{status: "ready_for_merge"}), do: :ok
  defp require_accepted_review_rework_status(%WorkPackage{}), do: {:tool_error, "work_package_not_ready_for_rework"}

  defp current_accepted_review_rework_pr(work_package, progress_events, evidence) do
    current_head_sha = MetadataProjection.latest_current_head_sha(progress_events)
    pr = MetadataProjection.metadata(progress_events, [], work_package.id, work_package.review_requirement).pr

    cond do
      not filled_string?(current_head_sha) ->
        {:tool_error, "missing_current_head_sha"}

      not exact_head_sha?(evidence["head_sha"], current_head_sha) ->
        {:tool_error, "stale_rework_head"}

      not is_map(pr) or not exact_head_sha?(pr["head_sha"], current_head_sha) ->
        {:tool_error, "missing_current_attached_pr"}

      PullRequestProgress.merged?(%{"merge_state" => pr["merge_state"]}) ->
        {:tool_error, "current_attached_pr_already_merged"}

      true ->
        identity = Map.take(pr, ["url", "repository", "number"]) |> Map.put("head_sha", current_head_sha)
        {:ok, String.downcase(current_head_sha), identity}
    end
  end

  defp exact_head_sha?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(String.trim(left)) == String.downcase(String.trim(right))
  end

  defp exact_head_sha?(_left, _right), do: false

  defp cleanup_worktree_runtime_in_transaction(repo, %Session{} = session, work_package_id) do
    with :ok <- lock_access_grant(repo, session.assignment.grant_id),
         {:ok, _architect_grant} <- WorkRequestScope.require_live_architect_grant(repo, session),
         :ok <- lock_work_package(repo, Session.work_package_id(session)),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, _work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, work_request, work_package} <- cleanup_worktree_runtime_scope(repo, work_package_id),
         true <- cleanup_worktree_claim_only_runtime?(repo, work_package_id) do
      WorkRequestRuntimeCleanup.cleanup(
        repo,
        work_request,
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
      from(work_package in WorkPackage,
        join: work_request in WorkRequest,
        on: work_request.id == work_package.work_request_id,
        where: work_package.id == ^work_package_id,
        select: {work_request, work_package},
        limit: 1
      )

    case repo.one(query) do
      {%WorkRequest{} = work_request, %WorkPackage{} = work_package} -> {:ok, work_request, work_package}
      nil -> {:error, :not_found}
    end
  end

  defp cleanup_worktree_claim_only_runtime?(repo, work_package_id) do
    now = DateTime.utc_now(:microsecond)
    context = WorkPackageActivity.context(repo, work_package_id)
    reason_codes = List.wrap(get_in(context, [:runtime_state, :reason_codes]))

    with {:ok, grants} <- AccessGrantRepository.list_for_work_package(repo, work_package_id) do
      not Enum.any?(grants, &live_worker_grant?(&1, now)) and
        get_in(context, [:runtime_state, :paused?]) != true and
        reason_codes -- ["claim_lease_active", "claim_lease_stale", "worker_recycled", "package_terminal"] == []
    end
  end

  defp live_worker_grant?(%AccessGrant{grant_role: "worker", revoked_at: nil, expires_at: nil}, _now), do: true

  defp live_worker_grant?(
         %AccessGrant{grant_role: "worker", revoked_at: nil, expires_at: %DateTime{} = expires_at},
         now
       ) do
    DateTime.compare(expires_at, now) == :gt
  end

  defp live_worker_grant?(%AccessGrant{}, _now), do: false

  defp cleanup_work_request_work_package_runtime_in_transaction(
         repo,
         %Session{} = session,
         %WorkRequest{} = work_request,
         %WorkPackage{},
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
             work_package,
             primary_scope?,
             filters
           ),
         :ok <- require_runtime_cleanup_delivery_state(work_package, delivery_evidence) do
      WorkRequestRuntimeCleanup.cleanup(
        repo,
        work_request,
        work_package,
        session.assignment,
        reason: reason,
        delivery_evidence: delivery_evidence
      )
    end
  end

  defp require_runtime_cleanup_delivery_state(%WorkPackage{}, %{"outcome" => "superseded"}), do: :ok

  defp require_runtime_cleanup_delivery_state(%WorkPackage{status: status}, %{"outcome" => "abandoned"})
       when status in ["planning", "ready_for_worker"],
       do: :ok

  defp require_runtime_cleanup_delivery_state(%WorkPackage{}, %{"outcome" => "abandoned"}),
    do: {:tool_error, "work_package_not_abandonable"}

  defp revoke_work_package_worker_key_in_transaction(
         repo,
         %Session{} = session,
         %WorkRequest{} = work_request,
         %WorkPackage{},
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
             work_package,
             primary_scope?,
             filters
           ),
         :ok <- WorkPackageWorkerRevoke.require_revoke_status(work_package),
         {:ok, grant} <- scoped_work_package_worker_grant_for_revoke(repo, grant_id, work_package_id, now),
         {:ok, recycled_work_package} <- WorkPackageWorkerRevoke.update_status(repo, work_package, now),
         {:ok, revoked_grant} <- revoke_live_work_package_worker_grant(repo, grant, now),
         {:ok, event} <-
           append_work_package_worker_revoke_event(
             repo,
             session,
             work_request,
             work_package,
             work_package.status,
             recycled_work_package,
             revoked_grant,
             reason
           ) do
      {:ok,
       work_package_worker_revoke_result(
         work_request,
         work_package,
         work_package.status,
         recycled_work_package,
         revoked_grant,
         event,
         reason
       )}
    end
  end

  defp scoped_work_package_worker_grant_for_revoke(repo, grant_id, work_package_id, %DateTime{} = now) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id),
         :ok <- require_work_package_worker_grant_scope(grant, work_package_id),
         :ok <- require_live_work_package_worker_grant_for_revoke(grant, now) do
      {:ok, grant}
    end
  end

  defp require_work_package_worker_grant_scope(%AccessGrant{work_package_id: work_package_id}, work_package_id),
    do: :ok

  defp require_work_package_worker_grant_scope(%AccessGrant{}, _work_package_id),
    do: {:tool_error, "worker_grant_out_of_scope"}

  defp require_live_work_package_worker_grant_for_revoke(%AccessGrant{grant_role: "worker"} = grant, now) do
    cond do
      grant.provenance == @child_worker_grant_provenance -> {:tool_error, "not_work_package_worker_grant"}
      not child_worker_grant_capabilities?(grant.capabilities || []) -> {:tool_error, "not_work_package_worker_grant"}
      match?(%DateTime{}, grant.revoked_at) -> {:tool_error, "work_package_worker_grant_already_revoked"}
      not live_expires_at?(grant.expires_at, now) -> {:tool_error, "work_package_worker_grant_expired"}
      true -> :ok
    end
  end

  defp require_live_work_package_worker_grant_for_revoke(%AccessGrant{}, _now),
    do: {:tool_error, "not_work_package_worker_grant"}

  defp child_worker_grant_capabilities?(capabilities) when is_list(capabilities),
    do: Enum.all?(capabilities, &(&1 in @child_worker_capabilities))

  defp child_worker_grant_capabilities?(_capabilities), do: false

  defp revoke_live_work_package_worker_grant(repo, %AccessGrant{} = grant, %DateTime{} = now) do
    query =
      from(access_grant in AccessGrant,
        where:
          access_grant.id == ^grant.id and access_grant.work_package_id == ^grant.work_package_id and
            access_grant.grant_role == "worker" and is_nil(access_grant.revoked_at) and
            (is_nil(access_grant.expires_at) or access_grant.expires_at > ^now)
      )

    case repo.update_all(query, set: [revoked_at: now, updated_at: now]) do
      {1, _rows} -> AccessGrantRepository.get(repo, grant.id)
      {0, _rows} -> classify_work_package_worker_revoke_miss(repo, grant.id, now)
    end
  end

  defp classify_work_package_worker_revoke_miss(repo, grant_id, %DateTime{} = now) do
    with {:ok, grant} <- AccessGrantRepository.get(repo, grant_id) do
      case require_live_work_package_worker_grant_for_revoke(grant, now) do
        :ok -> {:tool_error, "work_package_worker_revoke_conflict"}
        {:tool_error, reason} -> {:tool_error, reason}
      end
    end
  end

  defp append_work_package_worker_revoke_event(
         repo,
         %Session{} = session,
         %WorkRequest{} = work_request,
         %WorkPackage{},
         previous_work_package_status,
         %WorkPackage{} = recycled_work_package,
         %AccessGrant{} = grant,
         reason
       ) do
    payload =
      WorkPackageWorkerRevoke.payload(
        work_request,
        recycled_work_package,
        previous_work_package_status,
        grant,
        reason
      )

    PlanningRepository.append_audit_progress_event_for_work_package(repo, session.assignment, recycled_work_package.id, %{
      "summary" => "WorkRequest work-package worker grant revoked for cleanup",
      "body" =>
        "Cleanup reason: #{redacted_child_worker_revoke_reason(reason)}; " <>
          "WorkRequest: #{work_request.id}; WorkPackage: #{recycled_work_package.id}",
      "status" => "work_package_worker_key_revoked",
      "idempotency_key" => ProgressEvents.metadata_idempotency_key(payload),
      "payload" => payload
    })
  end

  defp work_package_worker_revoke_result(
         %WorkRequest{},
         %WorkPackage{},
         previous_work_package_status,
         %WorkPackage{} = recycled_work_package,
         %AccessGrant{} = grant,
         %ProgressEvent{} = event,
         _reason
       ) do
    reason_codes = WorkPackageWorkerRevoke.reason_codes(previous_work_package_status, recycled_work_package.status)

    %{
      "work_package" => work_package_payload(recycled_work_package),
      "revoked_worker_grant" => %{"id" => grant.id, "work_package_id" => grant.work_package_id},
      "closeout_affordance" => %{
        "status" => "revoked",
        "previous_work_package_status" => previous_work_package_status,
        "work_package_status" => recycled_work_package.status,
        "reason_codes" => reason_codes
      },
      "audit_event" => ProgressEvents.payload(event),
      "next_action" => "retry_record_work_package_delivery"
    }
  end

  defp run_architect_transaction(repo, fun, notify? \\ true) do
    result =
      case repo.transaction(fn -> rollback_architect_transaction_result(repo, fun.()) end) do
        {:ok, result} -> {:ok, result}
        {:error, {:tool_error, reason}} -> {:tool_error, reason}
        {:error, {:error, reason}} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end

    if notify?, do: DashboardPubSub.broadcast_changed_on_success(result), else: result
  end

  defp rollback_architect_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_architect_transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})
  defp rollback_architect_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp mutate_product_tree(repo, work_request_id, tool, created_by, mutation_fun) do
    run_architect_transaction(
      repo,
      fn ->
        with {:ok, result} <- mutation_fun.(),
             {:ok, _revision} <- record_current_product_tree_revision(repo, work_request_id, tool, created_by) do
          {:ok, result}
        end
      end,
      false
    )
  end

  defp record_current_product_tree_revision(repo, work_request_id, tool, created_by) do
    case Dashboard.work_request_detail(repo, work_request_id) do
      {:ok, detail} -> record_product_tree_revision(repo, work_request_id, tool, created_by, detail)
      {:error, reason} = error -> if missing_product_tree_schema_error?(reason), do: {:ok, nil}, else: error
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
      {:error, reason} = error -> if missing_product_tree_schema_error?(reason), do: {:ok, nil}, else: error
      result -> result
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
    |> json_safe_payload()
    |> Map.delete("latest_revision")
    |> Map.delete("execution_graph")
  end

  defp product_tree_revision_reason("record_work_package_delivery"),
    do: "WorkPackage delivery recorded in product tree through MCP."

  defp product_tree_revision_reason("reconcile_work_request"),
    do: "WorkPackage delivery reconciled in product tree through MCP."

  defp record_work_package_delivery_error(%Ecto.Changeset{} = changeset),
    do: changeset_invalid_params_error("record_work_package_delivery", "invalid_work_package_delivery", changeset)

  defp record_work_package_delivery_error(reason)
       when reason in [:delivery_outcome_conflict, :missing_strong_pr_evidence, :idempotency_key_conflict] do
    data = %{"tool" => "record_work_package_delivery", "reason" => Atom.to_string(reason)}
    {:error, -32_602, "Invalid params", data}
  end

  defp record_work_package_delivery_error(reason)
       when reason in [:active_runtime, :claim_not_current, :work_package_not_abandonable],
       do: delivery_closeout_precondition_error("record_work_package_delivery", reason)

  defp record_work_package_delivery_error(reason), do: architect_error(reason, "record_work_package_delivery")

  defp work_request_runtime_cleanup_error(reason) do
    if runtime_cleanup_precondition_error?(reason) do
      delivery_closeout_precondition_error(
        "cleanup_work_request_work_package_runtime",
        runtime_cleanup_precondition_reason(reason)
      )
    else
      architect_error(reason, "cleanup_work_request_work_package_runtime")
    end
  end

  defp runtime_cleanup_precondition_error?(reason),
    do: reason in [:active_runtime, :claim_not_current, :worker_grant_revoke_conflict, :mcp_session_binding_conflict]

  defp runtime_cleanup_precondition_reason(:worker_grant_revoke_conflict), do: :claim_not_current
  defp runtime_cleanup_precondition_reason(:mcp_session_binding_conflict), do: :claim_not_current
  defp runtime_cleanup_precondition_reason(reason), do: reason

  defp work_package_worker_revoke_tool_error(reason) when reason == "work_package_worker_revoke_conflict",
    do: delivery_closeout_precondition_error("revoke_work_package_worker_key", :claim_not_current)

  defp work_package_worker_revoke_tool_error(reason),
    do: {:error, -32_602, "Invalid params", %{"tool" => "revoke_work_package_worker_key", "reason" => reason}}

  defp delivery_closeout_precondition_error(tool, :claim_not_current),
    do: precondition_error(tool, "runtime_lease_conflict")

  defp delivery_closeout_precondition_error(tool, reason) when is_atom(reason),
    do: precondition_error(tool, Atom.to_string(reason))

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

  defp precondition_next_action("record_work_package_delivery", "active_runtime"),
    do: "release_worker_or_retry_after_stale"

  defp precondition_next_action("record_work_package_delivery", _reason), do: "retry_record_work_package_delivery"
  defp precondition_next_action(_tool, _reason), do: "retry_after_runtime_state_changes"

  defp architect_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp architect_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:expired, resource), do: auth_error({:unauthorized, :expired}, resource)
  defp architect_error(:assignment_revoked, resource), do: auth_error({:unauthorized, :revoked}, resource)

  defp architect_error(:architect_grant_required, resource),
    do: auth_error({:unauthorized, :architect_grant_required}, resource)

  defp architect_error(:insufficient_capability, resource),
    do: auth_error({:unauthorized, :insufficient_capability}, resource)

  defp architect_error({:authorization_policy_denied, %Decision{} = decision}, resource),
    do: MCPError.from_decision(decision, resource)

  defp architect_error({:authorization_policy_denied, code, message, data}, _resource),
    do: {:error, code, message, data}

  defp architect_error(:phase_scope_not_available, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:phase_scope_not_available, _missing_evidence}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:ambiguous_phase_scope, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:work_request_terminal, _terminal_state}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp architect_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)

  defp architect_error({:work_package_scope_violation, errors}, tool),
    do: invalid_params_error(tool, {:work_package_scope_violation, errors})

  defp architect_error(reason, tool),
    do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp auth_error(:unauthorized, resource),
    do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}

  defp auth_error({:unauthorized, reason}, resource),
    do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}

  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)

  defp auth_error(:forbidden, resource),
    do: {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}

  defp service_error(_reason, resource),
    do: {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}

  defp invalid_params_error(tool, {:work_package_scope_violation, errors}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "work_package_scope_violation",
       "validation_errors" => scope_validation_details(errors)
     }}
  end

  defp invalid_params_error(tool, {:blocker_closeout_required, blockers}) do
    message =
      "Active blockers exist in this finish scope. Pass blocker_closeout with decision resolved " <>
        "or still_active."

    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "blocker_closeout_required",
       "reason_code" => "blocker_closeout_required",
       "message" => message,
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

  defp invalid_params_error(tool, {:invalid_changeset, reason, %Ecto.Changeset{} = changeset}) do
    changeset_invalid_params_error(tool, reason, changeset)
  end

  defp invalid_params_error(tool, {:invalid_evidence, details}) do
    {:error, -32_602, "Invalid params",
     details
     |> Map.put("tool", tool)
     |> Map.put("reason", "invalid_evidence")}
  end

  defp invalid_params_error(tool, {:invalid_enum, _field, _allowed_values} = reason) do
    ErrorDetails.invalid_params_error(tool, reason)
  end

  defp invalid_params_error(tool, reason),
    do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp changeset_invalid_params_error(tool, reason, %Ecto.Changeset{} = changeset) do
    ErrorDetails.changeset_invalid_params_error(tool, reason, changeset)
  end

  defp scope_validation_details(errors) when is_list(errors), do: Enum.map(errors, &scope_validation_detail/1)
  defp scope_validation_details(error), do: scope_validation_details([error])

  defp scope_validation_detail({:invalid_constraints, field}),
    do: %{"field" => Atom.to_string(field), "reason" => "invalid_constraints"}

  defp scope_validation_detail({:invalid_allowed_file_globs, field}),
    do: %{"field" => Atom.to_string(field), "reason" => "invalid_allowed_file_globs"}

  defp scope_validation_detail({:invalid_path, field, value, reason}),
    do: %{"field" => Atom.to_string(field), "value" => value, "reason" => Atom.to_string(reason)}

  defp scope_validation_detail({:non_documentation_owned_glob, value}),
    do: %{"field" => "allowed_file_globs", "value" => value, "reason" => "non_documentation_owned_glob"}

  defp scope_validation_detail({:outside_allowed_paths, value, allowed_paths}),
    do: %{
      "field" => "allowed_file_globs",
      "value" => value,
      "reason" => "outside_allowed_paths",
      "allowed_paths" => allowed_paths
    }

  defp scope_validation_detail({:forbidden_path_overlap, value, forbidden_path}),
    do: %{
      "field" => "allowed_file_globs",
      "value" => value,
      "reason" => "forbidden_path_overlap",
      "forbidden_path" => forbidden_path
    }

  defp not_found_error(tool), do: {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}

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

  defp session_claimed_by(%Session{assignment: %{claimed_by: claimed_by}}) when is_binary(claimed_by) do
    case String.trim(claimed_by) do
      "" -> "architect"
      trimmed -> trimmed
    end
  end

  defp session_claimed_by(%Session{}), do: "architect"

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp redacted_child_worker_revoke_reason(reason) when is_binary(reason) do
    reason
    |> String.trim()
    |> Redactor.redact_text()
  end

  defp live_expires_at?(nil, %DateTime{}), do: true

  defp live_expires_at?(%DateTime{} = expires_at, %DateTime{} = now),
    do: DateTime.compare(expires_at, now) == :gt

  defp reconciliation_payload(reconciliation) when is_map(reconciliation) do
    reconciliation
    |> Map.drop([:delivery_board, "delivery_board"])
    |> json_safe_payload()
    |> Redactor.redact_output()
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
