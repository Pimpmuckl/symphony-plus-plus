defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ReviewReadiness do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.MetadataProjection
  alias SymphonyElixir.SymphonyPlusPlus.DashboardPubSub
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Config, ProgressEvents, Session, ToolResult, WorktreeScope}
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.ReviewRequirement
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @scope_guard_gate "scope_guard"

  @type repo :: module()
  @type mcp_error :: {:error, integer(), String.t(), map()}
  @type worker_result :: {:ok, term()} | {:tool_error, term()} | {:error, term()} | mcp_error()

  @spec submit_review_package(repo(), Session.t(), map(), Config.t()) :: worker_result()
  def submit_review_package(repo, %Session{} = session, arguments, %Config{} = config) do
    with {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, tests} <- optional_string_list(arguments, "tests"),
         {:ok, artifacts} <- optional_string_list(arguments, "artifacts") do
      artifacts = Enum.uniq(artifacts)

      submit_review_package_transaction(repo, session, arguments, artifacts, config, %{
        "type" => "review_package",
        "summary" => summary,
        "tests" => tests,
        "artifacts" => artifacts
      })
    end
  end

  @spec complete_review(repo(), Session.t(), map()) :: worker_result()
  def complete_review(repo, %Session{} = session, arguments) do
    with {:ok, reference} <- optional_string_argument(arguments, "reference"),
         {:ok, note} <- optional_string_argument(arguments, "note") do
      complete_review_transaction(repo, session, reference, note)
    end
  end

  @spec mark_ready(repo(), Session.t(), term(), function()) ::
          {:ok, {WorkPackage.t(), term(), [term()]}}
          | {:tool_error, term()}
          | {:error, term()}
          | mcp_error()
  def mark_ready(repo, %Session{} = session, blocker_closeout_plan, apply_blocker_closeout) do
    repo
    |> run_worker_transaction(fn ->
      with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
           :ok <- lock_work_package(repo, Session.work_package_id(session)),
           {:ok, blocker_closeout} <- apply_blocker_closeout.(repo, session, blocker_closeout_plan),
           {:ok, state} <- PlanningRepository.get_state(repo, Session.work_package_id(session)),
           {:ok, readiness_warnings} <- readiness_gates(state),
           ready_status = StateMachine.terminal_readiness_status(state.work_package),
           :ok <- StateMachine.validate_ready_transition(state.work_package, ready_status, actor(session)),
           {:ok, work_package} <-
             WorkPackageRepository.update_status(repo, state.work_package.id, state.work_package.status, ready_status) do
        {:ok, {work_package, blocker_closeout, readiness_warnings}}
      end
    end)
  end

  @spec maybe_put_readiness_warnings(map(), [term()]) :: map()
  def maybe_put_readiness_warnings(payload, []), do: payload
  def maybe_put_readiness_warnings(payload, warnings), do: Map.put(payload, "warnings", warnings)

  defp submit_review_package_transaction(repo, %Session{} = session, arguments, artifacts, config, payload) do
    case repo.transaction(fn ->
           submit_review_package_transaction_body(repo, session, arguments, artifacts, config, payload)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, {:mcp_error, code, message, data}} -> {:error, code, message, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp submit_review_package_transaction_body(repo, %Session{} = session, arguments, artifacts, config, payload) do
    work_package_id = Session.work_package_id(session)

    with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
         {:ok, requested_head_sha} <- optional_head_sha(arguments) do
      replay_head_sha = requested_head_sha || latest_current_head_sha(state.progress_events)
      arguments = maybe_put_headless_review_idempotency_key(arguments, requested_head_sha, payload)
      arguments = scope_review_rework_idempotency(arguments, state.progress_events)
      replay_arguments = maybe_put_review_head_sha(arguments, replay_head_sha)
      replay_payload = maybe_put_review_head_sha(payload, replay_head_sha)

      replay_existing_metadata_event(
        repo,
        session,
        replay_arguments,
        "submit_review_package",
        "review_package_submitted",
        replay_payload,
        events_after_latest_rework(state.progress_events)
      )
      |> case do
        {:ok, result} ->
          put_remaining_readiness_gates_or_rollback(repo, session, result)

        :not_found ->
          submit_new_review_package_transaction_body(
            repo,
            session,
            arguments,
            artifacts,
            payload,
            requested_head_sha,
            state,
            config
          )

        {:error, code, message, data} ->
          repo.rollback({:mcp_error, code, message, data})
      end
    else
      {:tool_error, reason} ->
        rollback_review_head_error(repo, reason)

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp submit_new_review_package_transaction_body(
         repo,
         %Session{} = session,
         arguments,
         artifacts,
         payload,
         requested_head_sha,
         state,
         config
       ) do
    case review_package_head_sha(requested_head_sha, state, config) do
      {:ok, review_head_sha, refresh} ->
        arguments = maybe_put_review_head_sha(arguments, review_head_sha)
        payload = maybe_put_review_head_sha(payload, review_head_sha)

        with :ok <- maybe_append_live_branch_refresh(repo, session, refresh),
             {:ok, current_state} <- PlanningRepository.get_state(repo, state.work_package.id),
             :ok <- require_rework_head_advanced(current_state.progress_events, review_head_sha),
             result <- submit_new_review_package(repo, session, arguments, artifacts, payload, review_head_sha),
             :ok <- confirm_live_branch_refresh(state.work_package, config, refresh) do
          put_remaining_readiness_gates_or_rollback(repo, session, result)
        else
          {:tool_error, reason} -> rollback_review_head_error(repo, reason)
          {:error, code, message, data} -> repo.rollback({:mcp_error, code, message, data})
          {:error, reason} -> repo.rollback(reason)
        end

      {:tool_error, reason} ->
        rollback_review_head_error(repo, reason)
    end
  end

  defp put_remaining_readiness_gates_or_rollback(repo, %Session{} = session, result) do
    case put_remaining_readiness_gates(repo, session, result) do
      {:ok, result} -> result
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp submit_new_review_package(repo, %Session{} = session, arguments, artifacts, payload, head_sha) do
    case ProgressEvents.append_metadata(repo, session, arguments, "submit_review_package", "review_package_submitted", payload) do
      {:ok, result} ->
        persist_review_artifacts_or_rollback(repo, session, artifacts, head_sha, result)

      {:error, code, message, data} ->
        repo.rollback({:mcp_error, code, message, data})
    end
  end

  defp review_package_head_sha(nil, %{progress_events: progress_events, work_package: work_package}, %Config{}) do
    case latest_current_head_sha(progress_events) do
      current_head_sha when is_binary(current_head_sha) -> {:ok, current_head_sha, nil}
      _missing_head -> if exact_head_required?(work_package), do: {:tool_error, "missing_current_head_sha"}, else: {:ok, nil, nil}
    end
  end

  defp review_package_head_sha(
         head_sha,
         %{progress_events: progress_events, work_package: %WorkPackage{} = work_package},
         %Config{} = config
       )
       when is_binary(head_sha) do
    current_head_sha = latest_current_head_sha(progress_events)

    cond do
      is_binary(current_head_sha) and head_sha_matches?(head_sha, current_head_sha) ->
        {:ok, head_sha, nil}

      is_binary(current_head_sha) and is_binary(head_sha) ->
        live_review_head_refresh(work_package, config, progress_events, head_sha)

      exact_head_required?(work_package) ->
        {:tool_error, "missing_current_head_sha"}

      true ->
        {:tool_error, "unbound_head_sha"}
    end
  end

  defp live_review_head_refresh(%WorkPackage{} = work_package, %Config{} = config, progress_events, head_sha) do
    with %ProgressEvent{payload: payload} = event <- latest_current_branch_event(progress_events),
         branch when is_binary(branch) <- Map.get(payload, "branch"),
         :ok <- WorktreeScope.require_live_review_head(work_package, config, branch, head_sha) do
      {:ok, head_sha, %{branch: branch, head_sha: head_sha, boundary: event.id}}
    else
      nil -> {:tool_error, {"stale_head_sha", "branch_proof_required"}}
      {:tool_error, reason} -> {:tool_error, {"stale_head_sha", reason}}
      _invalid_branch -> {:tool_error, {"stale_head_sha", "branch_proof_required"}}
    end
  end

  defp maybe_append_live_branch_refresh(_repo, %Session{}, nil), do: :ok

  defp maybe_append_live_branch_refresh(repo, %Session{} = session, refresh) do
    payload = %{
      "type" => "branch",
      "branch" => refresh.branch,
      "head_sha" => refresh.head_sha
    }

    arguments = %{"idempotency_key" => "live-review-head:#{refresh.boundary}:#{refresh.head_sha}"}

    case ProgressEvents.append_metadata(repo, session, arguments, "attach_branch", "branch_attached", payload) do
      {:ok, _result} -> :ok
      error -> error
    end
  end

  defp confirm_live_branch_refresh(%WorkPackage{}, %Config{}, nil), do: :ok

  defp confirm_live_branch_refresh(%WorkPackage{} = work_package, %Config{} = config, refresh) do
    case WorktreeScope.require_live_review_head(work_package, config, refresh.branch, refresh.head_sha) do
      :ok -> :ok
      {:tool_error, reason} -> {:tool_error, {"concurrent_head_change", reason}}
      {:error, reason} -> {:tool_error, {"concurrent_head_change", to_string(reason)}}
    end
  end

  defp rollback_review_head_error(repo, {reason, proof_failure}) do
    repo.rollback({:mcp_error, -32_602, "Invalid params", review_head_error_data(reason, proof_failure)})
  end

  defp rollback_review_head_error(repo, reason) do
    repo.rollback({:mcp_error, -32_602, "Invalid params", %{"tool" => "submit_review_package", "reason" => reason}})
  end

  defp review_head_error_data(reason, proof_failure) do
    %{
      "tool" => "submit_review_package",
      "reason" => reason,
      "proof_failure" => proof_failure,
      "recovery" => %{"next_action" => if(reason == "concurrent_head_change", do: "retry_submit_review_package", else: "attach_branch")}
    }
  end

  defp optional_head_sha(arguments) do
    case Map.fetch(arguments, "head_sha") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, head_sha} when is_binary(head_sha) ->
        case String.trim(head_sha) do
          "" -> {:ok, nil}
          trimmed -> {:ok, String.downcase(trimmed)}
        end

      {:ok, _head_sha} ->
        {:tool_error, "invalid_head_sha"}
    end
  end

  defp maybe_put_review_head_sha(map, head_sha) when is_binary(head_sha), do: Map.put(map, "head_sha", head_sha)
  defp maybe_put_review_head_sha(map, _head_sha), do: map

  defp maybe_put_headless_review_idempotency_key(arguments, nil, payload) do
    Map.put_new(arguments, "idempotency_key", ProgressEvents.metadata_idempotency_key(Map.put(payload, "source_tool", "submit_review_package")))
  end

  defp maybe_put_headless_review_idempotency_key(arguments, _requested_head_sha, _payload), do: arguments

  defp scope_review_rework_idempotency(arguments, progress_events) do
    case latest_accepted_review_rework(progress_events) do
      %ProgressEvent{id: id} ->
        fallback =
          :crypto.hash(:sha256, Jason.encode!([id, arguments]))
          |> Base.url_encode64(padding: false)

        case Map.get(arguments, "idempotency_key") do
          value when is_binary(value) -> Map.put(arguments, "idempotency_key", value <> ":rework:" <> id)
          nil -> Map.put(arguments, "idempotency_key", "rework:#{id}:#{fallback}")
          _invalid -> arguments
        end

      nil ->
        arguments
    end
  end

  defp persist_review_artifacts_or_rollback(repo, %Session{} = session, artifacts, head_sha, result) do
    case append_review_artifacts(repo, session, artifacts, head_sha) do
      :ok -> result
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp append_review_artifacts(repo, %Session{} = session, artifacts, head_sha) do
    work_package_id = Session.work_package_id(session)

    case PlanningRepository.list_artifacts(repo, work_package_id) do
      {:ok, existing_artifacts} ->
        append_review_artifacts(repo, work_package_id, existing_artifacts, head_sha, artifacts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp append_review_artifacts(repo, work_package_id, existing_artifacts, head_sha, artifacts) do
    Enum.reduce_while(artifacts, :ok, fn artifact, :ok ->
      case append_review_artifact(repo, work_package_id, existing_artifacts, head_sha, artifact) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp append_review_artifact(repo, work_package_id, existing_artifacts, head_sha, artifact) do
    if persisted_review_artifact?(existing_artifacts, work_package_id, head_sha, artifact) do
      :ok
    else
      attrs = %{
        "id" => review_artifact_id(work_package_id, head_sha, artifact),
        "work_package_id" => work_package_id,
        "path" => artifact,
        "title" => artifact,
        "kind" => "review",
        "uri" => review_artifact_uri(artifact)
      }

      case PlanningService.append_artifact(repo, attrs) do
        {:ok, _artifact} -> :ok
        {:error, :id_already_exists} -> replay_review_artifact(repo, work_package_id, head_sha, artifact)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp replay_review_artifact(repo, work_package_id, head_sha, artifact) do
    case PlanningRepository.list_artifacts(repo, work_package_id) do
      {:ok, artifacts} ->
        if persisted_review_artifact?(artifacts, work_package_id, head_sha, artifact) do
          :ok
        else
          {:error, :id_already_exists}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp review_artifact_id(work_package_id, head_sha, artifact) do
    material = [work_package_id, head_sha || "no-head", artifact] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp review_artifact_uri(artifact) do
    if String.contains?(artifact, "://"), do: artifact, else: nil
  end

  defp complete_review_transaction(repo, %Session{} = session, reference, note) do
    case repo.transaction(fn -> complete_review_transaction_body(repo, session, reference, note) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:mcp_error, code, message, data}} -> {:error, code, message, data}
      {:error, reason} -> {:error, reason}
    end
    |> DashboardPubSub.broadcast_changed_on_success()
  end

  defp complete_review_transaction_body(repo, %Session{} = session, reference, note) do
    work_package_id = Session.work_package_id(session)

    with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
         {:ok, requirement} <- required_review_requirement(state.work_package),
         {:ok, head_sha} <- required_current_review_head(state.progress_events),
         :ok <- require_rework_head_advanced(state.progress_events, head_sha),
         rework_id = accepted_review_rework_id(state.progress_events),
         payload <- review_completion_payload(work_package_id, requirement, head_sha, reference, note, rework_id),
         arguments <- review_completion_arguments(requirement, head_sha, note, rework_id),
         {:ok, result} <- ProgressEvents.append_metadata(repo, session, arguments, "complete_review", "review_complete", payload),
         {:ok, result} <- put_remaining_readiness_gates(repo, session, result) do
      result
    else
      {:tool_error, reason} -> repo.rollback({:mcp_error, -32_602, "Invalid params", %{"tool" => "complete_review", "reason" => reason}})
      {:error, code, message, data} -> repo.rollback({:mcp_error, code, message, data})
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp required_review_requirement(%WorkPackage{review_requirement: requirement}) when is_map(requirement), do: {:ok, requirement}
  defp required_review_requirement(%WorkPackage{}), do: {:tool_error, "review_not_required"}

  defp required_current_review_head(progress_events) do
    case latest_current_head_sha(progress_events) do
      head_sha when is_binary(head_sha) and head_sha != "" -> {:ok, head_sha}
      _head_sha -> {:tool_error, "review_current_head_missing"}
    end
  end

  defp review_completion_payload(work_package_id, requirement, head_sha, reference, note, rework_id) do
    %{
      "type" => "review_completion",
      "source_tool" => "complete_review",
      "work_package_id" => work_package_id,
      "review" => requirement,
      "review_fingerprint" => ReviewRequirement.fingerprint(requirement),
      "head_sha" => head_sha
    }
    |> put_if_present("reference", reference)
    |> put_if_present("note", note)
    |> put_if_present("accepted_review_rework_id", rework_id)
  end

  defp review_completion_arguments(requirement, head_sha, note, rework_id) do
    %{
      "summary" => "Required review completed",
      "body" => note,
      "status" => "review_complete",
      "idempotency_key" => review_completion_idempotency_key(requirement, head_sha, rework_id)
    }
  end

  defp review_completion_idempotency_key(requirement, head_sha, rework_id) do
    inputs = if is_binary(rework_id), do: [head_sha, requirement, rework_id], else: [head_sha, requirement]
    digest = :crypto.hash(:sha256, Jason.encode!(inputs)) |> Base.url_encode64(padding: false)
    "current:" <> digest
  end

  defp readiness_gates(state) do
    with {:ok, reasons} <- readiness_failure_reasons(state) do
      missing = missing_readiness_gates(reasons)

      if missing == [], do: {:ok, []}, else: {:error, {:readiness_failed, missing, reasons, []}}
    end
  end

  defp missing_readiness_gates(reasons) do
    reasons
    |> Enum.map(&Map.fetch!(&1, "gate"))
    |> Enum.uniq()
  end

  defp readiness_failure_reasons(state), do: {:ok, base_readiness_failure_reasons(state)}

  defp base_readiness_failure_reasons(state) do
    [
      {active_blocker?(state.progress_events), "no_active_blockers"},
      {merge_metadata_missing?(state, "branch"), "branch_attached"},
      {merge_metadata_missing?(state, "pr"), "pr_attached"},
      {current_pr_state_missing?(state), "current_pr_state"},
      {rework_head_not_advanced?(state), "rework_head_advanced"},
      {rework_current_pr_state_missing?(state), "rework_current_pr_state"},
      {ScopeGuard.missing?(state.work_package, state.progress_events), @scope_guard_gate},
      {review_current_head_missing?(state), "review_current_head"},
      {review_completion_missing?(state), "review_complete"},
      {investigation_findings_missing?(state), "findings_documented"}
    ]
    |> Enum.flat_map(fn
      {true, @scope_guard_gate} -> ScopeGuard.failure_reasons(state.work_package, state.progress_events)
      {true, "review_complete"} -> [readiness_failure_reason("review_complete", state)]
      {true, gate} -> [readiness_failure_reason(gate)]
      {false, _gate} -> []
    end)
  end

  defp readiness_failure_reason(gate) do
    %{
      "gate" => gate,
      "code" => gate,
      "message" => readiness_failure_message(gate)
    }
  end

  defp readiness_failure_reason("review_complete", state) do
    "review_complete"
    |> readiness_failure_reason()
    |> Map.merge(%{
      "review" => Redactor.redact_output(state.work_package.review_requirement),
      "head_sha" => latest_current_head_sha(state.progress_events)
    })
    |> drop_nil_values()
  end

  defp readiness_failure_message("no_active_blockers"), do: "Active blockers must be resolved."
  defp readiness_failure_message("branch_attached"), do: "Current branch metadata is missing."
  defp readiness_failure_message("pr_attached"), do: "Current PR metadata is missing."
  defp readiness_failure_message("current_pr_state"), do: "Current synced PR state is missing."
  defp readiness_failure_message("rework_head_advanced"), do: "Accepted review rework requires a different exact head."
  defp readiness_failure_message("rework_current_pr_state"), do: "Accepted review rework requires fresh synced PR state for the new head."
  defp readiness_failure_message("review_current_head"), do: "Required review cannot be completed until the current exact head is attached."
  defp readiness_failure_message("review_complete"), do: "Required review is not completed for the current exact head and requirement."
  defp readiness_failure_message("findings_documented"), do: "Investigation findings are missing."
  defp readiness_failure_message(_gate), do: "Readiness gate is not satisfied."

  defp merge_metadata_missing?(state, "pr") do
    current_head_sha = latest_current_head_sha(state.progress_events)

    merge_required?(state.work_package) and pr_required?(state.work_package) and
      not metadata_present?(state.progress_events, "pr", current_head_sha)
  end

  defp merge_metadata_missing?(state, metadata_type) do
    current_head_sha = latest_current_head_sha(state.progress_events)

    merge_required?(state.work_package) and
      not metadata_present?(state.progress_events, metadata_type, current_head_sha)
  end

  defp current_pr_state_missing?(state) do
    current_head_sha = latest_current_head_sha(state.progress_events)

    merge_required?(state.work_package) and pr_required?(state.work_package) and
      required_gate?(state.work_package, "current_pr_state") and
      not current_pr_state_present?(state.progress_events, current_head_sha)
  end

  defp rework_head_not_advanced?(state) do
    case latest_accepted_review_rework(state.progress_events) do
      %ProgressEvent{payload: payload} ->
        current_head_sha = latest_current_head_sha(state.progress_events)
        not is_binary(current_head_sha) or exact_head_sha?(Map.get(payload, "head_sha"), current_head_sha)

      nil ->
        false
    end
  end

  defp rework_current_pr_state_missing?(state) do
    not is_nil(latest_accepted_review_rework(state.progress_events)) and
      not fresh_rework_pr_state_present?(state.progress_events)
  end

  defp fresh_rework_pr_state_present?(progress_events) do
    current_head_sha = latest_current_head_sha(progress_events)

    case latest_attached_pr_ref(progress_events) do
      {:ok, attached_ref} ->
        Enum.any?(events_after_latest_rework(progress_events), &fresh_rework_pr_state_event?(&1, attached_ref, current_head_sha))

      {:tool_error, _reason} ->
        false
    end
  end

  defp fresh_rework_pr_state_event?(%ProgressEvent{payload: payload} = event, attached_ref, current_head_sha)
       when is_map(payload) do
    payload_type?(event, "pr", "sync_pr") and exact_head_sha?(payload["head_sha"], current_head_sha) and
      pr_payload_ref(payload) == attached_ref and current_pr_state_payload?(payload)
  end

  defp fresh_rework_pr_state_event?(%ProgressEvent{}, _attached_ref, _current_head_sha), do: false

  defp review_current_head_missing?(%{work_package: %WorkPackage{review_requirement: nil}}), do: false
  defp review_current_head_missing?(state), do: is_nil(latest_current_head_sha(state.progress_events))

  defp review_completion_missing?(%{work_package: %WorkPackage{review_requirement: nil}}), do: false

  defp review_completion_missing?(state) do
    requirement = state.work_package.review_requirement
    head_sha = latest_current_head_sha(state.progress_events)

    is_nil(head_sha) or
      not MetadataProjection.review_completion_present?(
        events_after_latest_rework(state.progress_events),
        state.work_package.id,
        head_sha,
        requirement
      )
  end

  defp investigation_findings_missing?(state), do: state.work_package.kind == "investigation" and state.findings == []

  defp merge_required?(%WorkPackage{} = work_package) do
    required_gate?(work_package, "human_merge") or required_gate?(work_package, "architect_merge")
  end

  defp exact_head_required?(%WorkPackage{} = work_package) do
    merge_required?(work_package) or is_map(work_package.review_requirement)
  end

  defp require_rework_head_advanced(progress_events, head_sha) do
    case latest_accepted_review_rework(progress_events) do
      %ProgressEvent{payload: payload} ->
        current_head_sha = latest_current_head_sha(progress_events)

        cond do
          not exact_head_sha?(head_sha, current_head_sha) -> {:tool_error, "rework_review_head_not_current"}
          exact_head_sha?(Map.get(payload, "head_sha"), head_sha) -> {:tool_error, "rework_head_not_advanced"}
          true -> :ok
        end

      nil ->
        :ok
    end
  end

  defp accepted_review_rework_id(progress_events) do
    case latest_accepted_review_rework(progress_events) do
      %ProgressEvent{id: id} -> id
      nil -> nil
    end
  end

  defp latest_accepted_review_rework(progress_events) do
    progress_events
    |> Enum.filter(&payload_type?(&1, "accepted_review_rework", "accept_review_rework"))
    |> List.last()
  end

  defp events_after_latest_rework(progress_events) do
    case latest_accepted_review_rework(progress_events) do
      %ProgressEvent{id: id} ->
        progress_events
        |> Enum.drop_while(&(&1.id != id))
        |> Enum.drop(1)

      nil ->
        progress_events
    end
  end

  defp persisted_review_artifact?(artifacts, work_package_id, head_sha, path) do
    expected_id = review_artifact_id(work_package_id, head_sha, path)
    Enum.any?(artifacts, &(&1.id == expected_id and &1.kind == "review" and &1.path == path))
  end

  defp latest_current_head_sha(progress_events) do
    case latest_metadata_head_sha(progress_events, "branch", "attach_branch") do
      head_sha when is_binary(head_sha) -> String.downcase(head_sha)
      missing -> missing
    end
  end

  defp latest_current_branch_event(progress_events) do
    progress_events
    |> Enum.reverse()
    |> Enum.find(&payload_type?(&1, "branch", "attach_branch"))
  end

  defp latest_metadata_head_sha(progress_events, type, source_tool) do
    progress_events
    |> Enum.filter(&payload_type?(&1, type, source_tool))
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{payload: payload} -> latest_metadata_payload_head_sha(payload)
      _event -> nil
    end)
  end

  defp latest_metadata_payload_head_sha(payload) do
    case Map.get(payload || %{}, "head_sha") do
      head_sha when is_binary(head_sha) and head_sha != "" -> head_sha
      _ -> nil
    end
  end

  defp active_blocker?(progress_events) do
    progress_events
    |> Enum.filter(&blocker_event?/1)
    |> Enum.reduce(%{}, fn event, blockers ->
      Map.put(blockers, blocker_id(event), Map.get(event.payload || %{}, "active") == true)
    end)
    |> Map.values()
    |> Enum.any?(& &1)
  end

  defp blocker_event?(%ProgressEvent{payload: payload}) when is_map(payload) do
    Map.get(payload, "type") == "blocker" and Map.get(payload, "source_tool") in ["report_blocker", "resolve_blocker"]
  end

  defp blocker_event?(%ProgressEvent{}), do: false

  defp blocker_id(%ProgressEvent{payload: payload, idempotency_key: idempotency_key, id: id}) do
    blocker_id = Map.get(payload || %{}, "blocker_id")
    normalize_blocker_id(blocker_id || idempotency_key || id)
  end

  defp required_gate?(%WorkPackage{} = work_package, gate) do
    case LifecycleService.policy_for(work_package) do
      {:ok, policy} -> gate in Map.get(policy, :required_gates, [])
      {:error, _reason} -> false
    end
  end

  defp pr_required?(%WorkPackage{kind: "investigation"}), do: false
  defp pr_required?(%WorkPackage{}), do: true

  defp metadata_present?(progress_events, "pr", head_sha) when is_binary(head_sha) do
    case latest_attached_pr_ref(progress_events) do
      {:ok, attached_ref} ->
        Enum.any?(progress_events, fn
          %ProgressEvent{payload: payload} = event when is_map(payload) ->
            payload_type?(event, "pr", ["attach_pr", "sync_pr"]) and head_sha_matches?(Map.get(payload, "head_sha"), head_sha) and
              pr_payload_ref(payload) == attached_ref

          %ProgressEvent{} ->
            false
        end)

      {:tool_error, _reason} ->
        false
    end
  end

  defp metadata_present?(progress_events, type, head_sha) when is_binary(head_sha) do
    Enum.any?(progress_events, fn
      %ProgressEvent{payload: payload} = event when is_map(payload) ->
        payload_type?(event, type, metadata_tool(type)) and head_sha_matches?(Map.get(payload, "head_sha"), head_sha)

      %ProgressEvent{} ->
        false
    end)
  end

  defp metadata_present?(_progress_events, _type, _head_sha), do: false

  defp current_pr_state_present?(progress_events, head_sha) when is_binary(head_sha) do
    case latest_attached_pr_ref_with_ledger_boundary(progress_events) do
      {:ok, attached_ref, attach_boundary} ->
        Enum.any?(progress_events, fn
          %ProgressEvent{payload: payload} = event when is_map(payload) ->
            current_pr_state_event?(event, attach_boundary) and head_sha_matches?(Map.get(payload, "head_sha"), head_sha) and
              pr_payload_ref(payload) == attached_ref and current_pr_state_payload?(payload)

          %ProgressEvent{} ->
            false
        end)

      {:tool_error, _reason} ->
        false
    end
  end

  defp current_pr_state_present?(_progress_events, _head_sha), do: false

  defp current_pr_state_event?(%ProgressEvent{} = event, {:repair_sync, repair_boundary}) do
    payload_type?(event, "pr", "sync_pr") and
      (attach_boundary(event) == repair_boundary or
         progress_after_pr_attach_boundary?(event, repair_boundary))
  end

  defp current_pr_state_event?(%ProgressEvent{} = event, attach_boundary) do
    (payload_type?(event, "pr", "attach_pr") and attach_boundary(event) == attach_boundary) or
      (payload_type?(event, "pr", "sync_pr") and progress_after_pr_attach_boundary?(event, attach_boundary))
  end

  defp progress_after_pr_attach_boundary?(%ProgressEvent{} = event, {:sequence, attach_boundary}) do
    progress_event_sequence_order(event) > attach_boundary
  end

  defp progress_after_pr_attach_boundary?(%ProgressEvent{} = event, {:chronological, attach_boundary}) do
    progress_event_chronological_order(event) > attach_boundary
  end

  defp progress_after_pr_attach_boundary?(%ProgressEvent{}, _attach_boundary), do: false

  defp current_pr_state_payload?(payload) when is_map(payload) do
    semantic_pr_state?(payload, "check_summary", ["conclusion", "state", "status"]) or
      semantic_pr_state?(payload, "review_state", ["decision", "state", "status"]) or
      semantic_pr_state?(payload, "merge_state", ["mergeable_state", "state", "status"]) or
      semantic_pr_boolean?(payload, "merge_state", ["mergeable", "merged"])
  end

  defp semantic_pr_state?(payload, key, semantic_keys) do
    case Map.get(payload, key) do
      value when is_map(value) ->
        Enum.any?(semantic_keys, fn semantic_key ->
          semantic_pr_value?(value, semantic_key)
        end)

      _value ->
        false
    end
  end

  defp semantic_pr_value(value, key), do: Map.get(value, key) || Map.get(value, String.to_atom(key))

  defp semantic_pr_value?(value, "state") do
    case semantic_pr_value(value, "state") do
      state when is_binary(state) ->
        normalized = state |> String.trim() |> String.downcase()
        normalized != "" and normalized not in ["open", "closed"]

      _state ->
        false
    end
  end

  defp semantic_pr_value?(value, key), do: value |> semantic_pr_value(key) |> filled_string?()

  defp semantic_pr_boolean?(payload, key, semantic_keys) do
    case Map.get(payload, key) do
      value when is_map(value) ->
        Enum.any?(semantic_keys, fn semantic_key ->
          is_boolean(Map.get(value, semantic_key)) or is_boolean(Map.get(value, String.to_atom(semantic_key)))
        end)

      _value ->
        false
    end
  end

  defp latest_attached_pr_ref(progress_events) do
    case latest_attached_pr_ref_with_ledger_boundary(progress_events) do
      {:ok, ref, _boundary} -> {:ok, ref}
      {:tool_error, reason} -> {:tool_error, reason}
    end
  end

  defp latest_attached_pr_ref_with_ledger_boundary(progress_events) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find_value(&attached_or_repaired_pr_ref_with_boundary/1)
    |> case do
      nil -> {:tool_error, "missing_attached_pr"}
      {ref, boundary} -> {:ok, ref, boundary}
    end
  end

  defp progress_event_sequence_order(%ProgressEvent{sequence: sequence, created_at: created_at, id: id}) when is_integer(sequence) do
    {1, sequence, timestamp_sort_value(created_at), id || ""}
  end

  defp progress_event_sequence_order(%ProgressEvent{created_at: created_at, id: id}) do
    {0, timestamp_sort_value(created_at), id || ""}
  end

  defp timestamp_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp timestamp_sort_value(nil), do: -1

  defp attach_boundary(%ProgressEvent{sequence: sequence} = event) when is_integer(sequence) do
    {:sequence, progress_event_sequence_order(event)}
  end

  defp attach_boundary(%ProgressEvent{} = event), do: {:chronological, progress_event_chronological_order(event)}
  defp chronological_progress_events(progress_events), do: Enum.sort_by(progress_events, &progress_event_chronological_order/1)

  defp progress_event_chronological_order(%ProgressEvent{created_at: created_at, sequence: sequence, id: id}) do
    {timestamp_sort_value(created_at), sequence || 0, id || ""}
  end

  defp attached_or_repaired_pr_ref_with_boundary(%ProgressEvent{} = event) do
    attached_pr_ref_with_boundary(event) || repaired_pr_ref_with_boundary(event)
  end

  defp attached_pr_ref_with_boundary(%ProgressEvent{payload: payload} = event) when is_map(payload) do
    if payload_type?(event, "pr", "attach_pr"), do: pr_payload_ref_with_sequence(payload, attach_boundary(event))
  end

  defp attached_pr_ref_with_boundary(_event), do: nil

  defp repaired_pr_ref_with_boundary(%ProgressEvent{payload: payload} = event) when is_map(payload) do
    if payload_type?(event, "pr", "sync_pr") and Map.get(payload, "attachment_repair") == true do
      pr_payload_ref_with_sequence(payload, {:repair_sync, attach_boundary(event)})
    end
  end

  defp repaired_pr_ref_with_boundary(_event), do: nil

  defp pr_payload_ref_with_sequence(payload, sequence) do
    case pr_payload_ref(payload) do
      nil -> nil
      ref -> {ref, sequence}
    end
  end

  defp pr_payload_ref(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_integer(number), do: normalized_pr_ref(repository, number)
  defp pr_payload_ref(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_binary(number), do: normalized_pr_ref(repository, number)

  defp pr_payload_ref(%{"url" => url}) when is_binary(url) do
    case PullRequest.parse(%{"url" => url}, nil) do
      {:ok, ref} -> normalized_pr_ref(ref.repository, ref.number)
      {:error, _reason} -> legacy_url_ref(url)
    end
  end

  defp pr_payload_ref(_payload), do: nil

  defp normalized_pr_ref(repository, number) when is_binary(repository) do
    {String.downcase(repository), pr_number_argument(number) || number}
  end

  defp legacy_url_ref(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> if String.downcase(host) == "github.com", do: nil, else: {:url, url}
      _uri -> {:url, url}
    end
  rescue
    _error in URI.Error -> {:url, url}
  end

  defp pr_number_argument(value) when is_integer(value) and value > 0, do: value

  defp pr_number_argument(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 -> number
      _parse -> nil
    end
  end

  defp pr_number_argument(_value), do: nil

  defp metadata_tool("branch"), do: "attach_branch"
  defp metadata_tool("pr"), do: "attach_pr"

  defp head_sha_matches?(left, right) when is_binary(left) and is_binary(right) do
    PullRequest.head_sha_matches?(String.downcase(left), String.downcase(right))
  end

  defp head_sha_matches?(_left, _right), do: false

  defp exact_head_sha?(left, right) when is_binary(left) and is_binary(right) do
    String.downcase(String.trim(left)) == String.downcase(String.trim(right))
  end

  defp exact_head_sha?(_left, _right), do: false

  defp payload_type?(%ProgressEvent{payload: payload}, type, source_tools) when is_map(payload) and is_list(source_tools) do
    Map.get(payload, "type") == type and Map.get(payload, "source_tool") in source_tools
  end

  defp payload_type?(%ProgressEvent{payload: payload}, type, source_tool) when is_map(payload) do
    Map.get(payload, "type") == type and Map.get(payload, "source_tool") == source_tool
  end

  defp payload_type?(%ProgressEvent{}, _type, _source_tool), do: false

  defp put_remaining_readiness_gates(repo, %Session{} = session, %{"structuredContent" => payload}) do
    with {:ok, state} <- PlanningRepository.get_state(repo, Session.work_package_id(session)),
         {:ok, reasons} <- readiness_failure_reasons(state) do
      result = payload |> Map.put("remaining_readiness_gates", missing_readiness_gates(reasons)) |> ToolResult.agent_tool_result()
      {:ok, result}
    end
  end

  defp replay_existing_metadata_event(repo, %Session{} = session, arguments, tool, status, payload, progress_events) do
    ProgressEvents.replay_metadata(repo, session, arguments, tool, status, payload, progress_events)
  end

  defp run_worker_transaction(repo, fun) do
    case repo.transaction(fn -> rollback_worker_transaction_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:mcp_error, code, message, data}} -> {:error, code, message, data}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
    |> DashboardPubSub.broadcast_changed_on_success()
  end

  defp rollback_worker_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_worker_transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})

  defp rollback_worker_transaction_result(repo, {:error, code, message, data}) do
    repo.rollback({:mcp_error, code, message, data})
  end

  defp rollback_worker_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp required_argument(arguments, key) do
    case Map.get(arguments, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:tool_error, "missing_#{key}"}
          trimmed -> {:ok, trimmed}
        end

      _value ->
        {:tool_error, "missing_#{key}"}
    end
  end

  defp optional_string_list(arguments, key) do
    case Map.get(arguments, key, []) do
      values when is_list(values) ->
        if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
          {:ok, Enum.map(values, &String.trim/1)}
        else
          {:tool_error, "invalid_#{key}"}
        end

      _value ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  defp optional_string_argument(arguments, key, default \\ nil) do
    case Map.fetch(arguments, key) do
      :error ->
        {:ok, default}

      {:ok, nil} ->
        {:ok, default}

      {:ok, value} when is_binary(value) ->
        case String.trim(value) do
          "" -> {:ok, default}
          trimmed -> {:ok, trimmed}
        end

      {:ok, _value} ->
        {:tool_error, "invalid_#{key}"}
    end
  end

  defp normalize_blocker_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_blocker_id(value), do: value
  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)
  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp actor(%Session{} = session) do
    %{
      grant_id: session.assignment.grant_id,
      grant_role: session.assignment.grant_role,
      capabilities: session.assignment.capabilities,
      work_package_id: session.assignment.work_package_id
    }
  end
end
