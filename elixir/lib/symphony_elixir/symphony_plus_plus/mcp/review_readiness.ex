defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ReviewReadiness do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.MetadataProjection
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ProgressEvents
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @complete_plan_statuses ["done", "completed", "skipped"]
  @review_promotable_work_package_statuses ["ready_for_worker", "claimed", "planning", "implementing"]
  @scope_guard_gate "scope_guard"

  @type repo :: module()
  @type mcp_error :: {:error, integer(), String.t(), map()}
  @type worker_result :: {:ok, term()} | {:tool_error, term()} | {:error, term()} | mcp_error()

  @spec submit_review_package(repo(), Session.t(), map()) :: worker_result()
  def submit_review_package(repo, %Session{} = session, arguments) do
    with {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, tests} <- required_string_list(arguments, "tests"),
         {:ok, artifacts} <- required_string_list(arguments, "artifacts"),
         artifacts = Enum.uniq(artifacts),
         {:ok, acceptance_criteria_met} <- optional_boolean(arguments, "acceptance_criteria_met", nil) do
      submit_review_package_transaction(repo, session, arguments, artifacts, %{
        "type" => "review_package",
        "summary" => summary,
        "tests" => tests,
        "artifacts" => artifacts,
        "acceptance_criteria_met" => acceptance_criteria_met
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
           {:ok, readiness_warnings} <- readiness_gates(repo, state),
           ready_status = StateMachine.terminal_readiness_status(state.work_package),
           :ok <- StateMachine.validate_ready_transition(state.work_package, ready_status, actor(session)),
           {:ok, work_package} <-
             WorkPackageRepository.update_status(repo, state.work_package.id, state.work_package.status, ready_status) do
        {:ok, {work_package, blocker_closeout, readiness_warnings}}
      end
    end)
  end

  @spec child_ready_approval_gates(repo(), map()) ::
          :ok | {:error, {:readiness_failed, [String.t()], [map()]}} | {:error, term()}
  def child_ready_approval_gates(repo, state) do
    with {:ok, reasons} <- readiness_failure_reasons(repo, state) do
      reasons = Enum.reject(reasons, &(Map.get(&1, "gate") in ["status_ci_waiting", "status_reviewing"]))
      missing = missing_readiness_gates(reasons)

      if missing == [], do: :ok, else: {:error, {:readiness_failed, missing, reasons}}
    end
  end

  @spec maybe_put_readiness_warnings(map(), [term()]) :: map()
  def maybe_put_readiness_warnings(payload, []), do: payload
  def maybe_put_readiness_warnings(payload, warnings), do: Map.put(payload, "warnings", warnings)

  defp submit_review_package_transaction(repo, %Session{} = session, arguments, artifacts, payload) do
    case repo.transaction(fn ->
           submit_review_package_transaction_body(repo, session, arguments, artifacts, payload)
         end) do
      {:ok, result} -> {:ok, result}
      {:error, {:mcp_error, code, message, data}} -> {:error, code, message, data}
      {:error, reason} -> {:error, reason}
    end
  end

  defp submit_review_package_transaction_body(repo, %Session{} = session, arguments, artifacts, payload) do
    work_package_id = Session.work_package_id(session)

    with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
         {:ok, requested_head_sha} <- optional_head_sha(arguments) do
      replay_head_sha = requested_head_sha || latest_current_head_sha(state.progress_events)
      arguments = maybe_put_headless_review_idempotency_key(arguments, requested_head_sha, payload)
      arguments = maybe_put_review_head_sha(arguments, replay_head_sha)
      payload = maybe_put_review_head_sha(payload, replay_head_sha)

      submit_or_replay_review_package(
        repo,
        session,
        arguments,
        artifacts,
        payload,
        replay_head_sha,
        state.work_package,
        state.progress_events
      )
    else
      {:tool_error, reason} ->
        repo.rollback({:mcp_error, -32_602, "Invalid params", %{"tool" => "submit_review_package", "reason" => reason}})

      {:error, reason} ->
        repo.rollback(reason)
    end
  end

  defp submit_or_replay_review_package(
         repo,
         %Session{} = session,
         arguments,
         artifacts,
         payload,
         requested_head_sha,
         work_package,
         progress_events
       ) do
    case replay_existing_metadata_event(repo, session, arguments, "submit_review_package", "review_package_submitted", payload, progress_events) do
      {:ok, result} ->
        result

      :not_found ->
        submit_new_review_package(
          repo,
          session,
          arguments,
          artifacts,
          payload,
          requested_head_sha,
          work_package,
          progress_events
        )

      {:error, code, message, data} ->
        repo.rollback({:mcp_error, code, message, data})
    end
  end

  defp submit_new_review_package(repo, %Session{} = session, arguments, artifacts, payload, requested_head_sha, work_package, progress_events) do
    case review_package_head_sha(requested_head_sha, progress_events, work_package) do
      {:ok, head_sha} ->
        case ProgressEvents.append_metadata(repo, session, arguments, "submit_review_package", "review_package_submitted", payload) do
          {:ok, result} ->
            persist_review_artifacts_and_promote_or_rollback(repo, session, artifacts, head_sha, result, work_package)

          {:error, code, message, data} ->
            repo.rollback({:mcp_error, code, message, data})
        end

      {:tool_error, reason} ->
        repo.rollback({:mcp_error, -32_602, "Invalid params", %{"tool" => "submit_review_package", "reason" => reason}})
    end
  end

  defp review_package_head_sha(nil, progress_events, %WorkPackage{} = work_package) do
    case latest_current_head_sha(progress_events) do
      current_head_sha when is_binary(current_head_sha) -> {:ok, current_head_sha}
      _missing_head -> missing_review_package_head_sha(work_package)
    end
  end

  defp review_package_head_sha(head_sha, progress_events, %WorkPackage{} = work_package) when is_binary(head_sha) do
    current_head_sha = latest_current_head_sha(progress_events)

    cond do
      is_binary(current_head_sha) and head_sha == current_head_sha ->
        {:ok, head_sha}

      is_binary(current_head_sha) and is_binary(head_sha) ->
        {:tool_error, "stale_head_sha"}

      merge_required?(work_package) ->
        {:tool_error, "missing_current_head_sha"}

      true ->
        {:ok, head_sha}
    end
  end

  defp missing_review_package_head_sha(%WorkPackage{} = work_package) do
    if merge_required?(work_package) do
      {:tool_error, "missing_current_head_sha"}
    else
      {:tool_error, "missing_head_sha"}
    end
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
          trimmed -> {:ok, trimmed}
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

  defp persist_review_artifacts_and_promote_or_rollback(repo, %Session{} = session, artifacts, head_sha, result, %WorkPackage{} = work_package) do
    with :ok <- append_review_artifacts(repo, session, artifacts, head_sha),
         :ok <- promote_stale_package_to_reviewing(repo, work_package) do
      result
    else
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
  end

  defp complete_review_transaction_body(repo, %Session{} = session, reference, note) do
    work_package_id = Session.work_package_id(session)

    with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
         :ok <- lock_work_package(repo, work_package_id),
         {:ok, state} <- PlanningRepository.get_state(repo, work_package_id),
         {:ok, requirement} <- required_review_requirement(state.work_package),
         {:ok, head_sha} <- required_current_review_head(state.progress_events),
         payload <- review_completion_payload(work_package_id, requirement, head_sha, reference, note),
         arguments <- review_completion_arguments(requirement, head_sha, note),
         {:ok, result} <- ProgressEvents.append_metadata(repo, session, arguments, "complete_review", "review_complete", payload),
         :ok <- promote_stale_package_to_reviewing(repo, state.work_package) do
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

  defp review_completion_payload(work_package_id, requirement, head_sha, reference, note) do
    %{
      "type" => "review_completion",
      "source_tool" => "complete_review",
      "work_package_id" => work_package_id,
      "review" => requirement,
      "head_sha" => head_sha
    }
    |> put_if_present("reference", reference)
    |> put_if_present("note", note)
  end

  defp review_completion_arguments(requirement, head_sha, note) do
    %{
      "summary" => "Required review completed",
      "body" => note,
      "status" => "review_complete",
      "idempotency_key" => review_completion_idempotency_key(requirement, head_sha)
    }
  end

  defp review_completion_idempotency_key(requirement, head_sha) do
    digest = :crypto.hash(:sha256, Jason.encode!([head_sha, requirement])) |> Base.url_encode64(padding: false)
    "current:" <> digest
  end

  defp promote_stale_package_to_reviewing(repo, %WorkPackage{status: status} = work_package)
       when status in @review_promotable_work_package_statuses do
    promote_package_status_to_reviewing(repo, work_package.id, status, 0)
  end

  defp promote_stale_package_to_reviewing(_repo, %WorkPackage{}), do: :ok

  defp promote_package_status_to_reviewing(repo, work_package_id, expected_status, attempts) do
    case WorkPackageRepository.update_status(repo, work_package_id, expected_status, "reviewing") do
      {:ok, %WorkPackage{}} ->
        :ok

      {:error, :stale_status} when attempts < 3 ->
        retry_review_promotion_from_latest_status(repo, work_package_id, attempts + 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_review_promotion_from_latest_status(repo, work_package_id, attempts) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %WorkPackage{status: status}} when status in @review_promotable_work_package_statuses ->
        promote_package_status_to_reviewing(repo, work_package_id, status, attempts)

      {:ok, %WorkPackage{}} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp readiness_gates(repo, state) do
    with {:ok, reasons} <- readiness_failure_reasons(repo, state) do
      missing = missing_readiness_gates(reasons)

      if missing == [], do: {:ok, []}, else: {:error, {:readiness_failed, missing, reasons, []}}
    end
  end

  defp missing_readiness_gates(reasons) do
    reasons
    |> Enum.map(&Map.fetch!(&1, "gate"))
    |> Enum.uniq()
  end

  defp readiness_failure_reasons(repo, state) do
    with {:ok, phase_child_reasons} <- phase_child_readiness_failure_reasons(repo, state.work_package) do
      {:ok, base_readiness_failure_reasons(state) ++ phase_child_reasons}
    end
  end

  defp base_readiness_failure_reasons(state) do
    [
      {readiness_status_missing?(state.work_package), readiness_status_gate(state.work_package)},
      {active_blocker?(state.progress_events), "no_active_blockers"},
      {incomplete_plan?(state), "plan_complete"},
      {acceptance_missing?(state), "acceptance_criteria_met"},
      {tests_missing?(state), "tests_passed"},
      {merge_metadata_missing?(state, "branch"), "branch_attached"},
      {merge_metadata_missing?(state, "pr"), "pr_attached"},
      {current_pr_state_missing?(state), "current_pr_state"},
      {ScopeGuard.missing?(state.work_package, state.progress_events), @scope_guard_gate},
      {review_artifacts_missing?(state), "review_artifacts_attached"},
      {review_current_head_missing?(state), "review_current_head"},
      {review_completion_missing?(state), "review_complete"},
      {investigation_findings_missing?(state), "findings_documented"},
      {investigation_recommendation_missing?(state), "recommendation_artifact_recorded"}
    ]
    |> Enum.flat_map(fn
      {true, @scope_guard_gate} -> ScopeGuard.failure_reasons(state.work_package, state.progress_events)
      {true, "review_complete"} -> [readiness_failure_reason("review_complete", state)]
      {true, gate} -> [readiness_failure_reason(gate)]
      {false, _gate} -> []
    end)
  end

  defp phase_child_readiness_failure_reasons(repo, %WorkPackage{kind: "phase_child"} = child) do
    with {:ok, phase} <- readiness_phase(repo, child),
         {:ok, parent} <- readiness_phase_parent(repo, child) do
      reasons =
        []
        |> maybe_add_readiness_reason(phase.status != "active", "phase_active")
        |> maybe_add_readiness_reason(not readiness_phase_child_scope_ok?(child, parent), "phase_child_scope")

      {:ok, Enum.reverse(reasons)}
    end
  end

  defp phase_child_readiness_failure_reasons(_repo, %WorkPackage{}), do: {:ok, []}

  defp readiness_phase(repo, %WorkPackage{phase_id: phase_id}) when is_binary(phase_id) do
    if filled_string?(phase_id) do
      case PhaseRepository.get(repo, phase_id) do
        {:ok, phase} -> {:ok, phase}
        {:error, :not_found} -> {:ok, %{status: nil}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, %{status: nil}}
    end
  end

  defp readiness_phase(_repo, %WorkPackage{}), do: {:ok, %{status: nil}}

  defp readiness_phase_parent(repo, %WorkPackage{parent_id: parent_id}) when is_binary(parent_id) do
    if filled_string?(parent_id) do
      case WorkPackageRepository.get(repo, parent_id) do
        {:ok, parent} -> {:ok, parent}
        {:error, :not_found} -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, nil}
    end
  end

  defp readiness_phase_parent(_repo, %WorkPackage{}), do: {:ok, nil}

  defp readiness_phase_child_scope_ok?(%WorkPackage{} = child, %WorkPackage{} = parent) do
    child.parent_id == parent.id and child.phase_id == parent.phase_id and child.repo == parent.repo and child.base_branch == parent.base_branch and
      require_phase_child_file_scope(child, parent) == :ok
  end

  defp readiness_phase_child_scope_ok?(%WorkPackage{}, _parent), do: false

  defp maybe_add_readiness_reason(reasons, true, gate), do: [readiness_failure_reason(gate) | reasons]
  defp maybe_add_readiness_reason(reasons, false, _gate), do: reasons

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

  defp readiness_failure_message("status_ci_waiting"), do: "Package must be waiting on validation."
  defp readiness_failure_message("status_reviewing"), do: "Package must be in review or validation."
  defp readiness_failure_message("no_active_blockers"), do: "Active blockers must be resolved."
  defp readiness_failure_message("plan_complete"), do: "Package plan is missing or still has pending items."
  defp readiness_failure_message("acceptance_criteria_met"), do: "Acceptance criteria evidence is missing."
  defp readiness_failure_message("tests_passed"), do: "Focused test evidence is missing."
  defp readiness_failure_message("branch_attached"), do: "Current branch metadata is missing."
  defp readiness_failure_message("pr_attached"), do: "Current PR metadata is missing."
  defp readiness_failure_message("current_pr_state"), do: "Current synced PR state is missing."
  defp readiness_failure_message("review_artifacts_attached"), do: "Current-head validation artifacts are missing."
  defp readiness_failure_message("review_current_head"), do: "Required review cannot be completed until the current exact head is attached."
  defp readiness_failure_message("review_complete"), do: "Required review is not completed for the current exact head and requirement."
  defp readiness_failure_message("findings_documented"), do: "Investigation findings are missing."
  defp readiness_failure_message("recommendation_artifact_recorded"), do: "Investigation recommendation artifact is missing."
  defp readiness_failure_message("phase_active"), do: "Phase must be active before phase child readiness."
  defp readiness_failure_message("phase_child_scope"), do: "Phase child must remain inside its parent phase repo, base branch, and file scope."
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

  defp review_current_head_missing?(%{work_package: %WorkPackage{review_requirement: nil}}), do: false
  defp review_current_head_missing?(state), do: is_nil(latest_current_head_sha(state.progress_events))

  defp review_completion_missing?(%{work_package: %WorkPackage{review_requirement: nil}}), do: false

  defp review_completion_missing?(state) do
    requirement = state.work_package.review_requirement
    head_sha = latest_current_head_sha(state.progress_events)

    is_nil(head_sha) or
      not MetadataProjection.review_completion_present?(
        state.progress_events,
        state.work_package.id,
        head_sha,
        requirement
      )
  end

  defp review_artifacts_missing?(state) do
    merge_required?(state.work_package) and not current_review_artifacts_present?(state)
  end

  defp current_review_artifacts_present?(state) do
    current_head_sha = latest_current_head_sha(state.progress_events)

    case latest_review_package_event(state.progress_events, current_head_sha) do
      %ProgressEvent{} = event ->
        artifacts = review_package_artifact_paths(event, current_head_sha)

        artifacts != [] and
          Enum.all?(artifacts, &persisted_review_artifact?(state.artifacts, state.work_package.id, current_head_sha, &1))

      nil ->
        false
    end
  end

  defp investigation_findings_missing?(state), do: state.work_package.kind == "investigation" and state.findings == []

  defp investigation_recommendation_missing?(state) do
    state.work_package.kind == "investigation" and not recommendation_artifact_recorded?(state.artifacts, state.work_package.id)
  end

  defp merge_required?(%WorkPackage{} = work_package) do
    required_gate?(work_package, "human_merge") or required_gate?(work_package, "architect_merge")
  end

  defp latest_review_package_event(progress_events, current_head_sha) do
    progress_events
    |> current_head_review_package_events(current_head_sha)
    |> List.last()
  end

  defp current_head_review_package_events(progress_events, current_head_sha) do
    Enum.filter(progress_events, fn event ->
      payload_type?(event, "review_package", "submit_review_package") and current_head_review_package?(event, current_head_sha)
    end)
  end

  defp current_head_review_package?(%ProgressEvent{payload: payload}, current_head_sha) when is_map(payload) do
    review_head_matches?(payload, current_head_sha)
  end

  defp current_head_review_package?(%ProgressEvent{}, _current_head_sha), do: false

  defp review_head_matches?(payload, :any_head) when is_map(payload) do
    head_sha = Map.get(payload, "head_sha")
    is_binary(head_sha) and String.trim(head_sha) != ""
  end

  defp review_head_matches?(payload, current_head_sha) when is_map(payload) and is_binary(current_head_sha) do
    Map.get(payload, "head_sha") == current_head_sha
  end

  defp review_head_matches?(_payload, _current_head_sha), do: false

  defp review_package_artifact_paths(%ProgressEvent{payload: payload}, current_head_sha) when is_map(payload) do
    artifacts = Map.get(payload, "artifacts")

    if is_list(artifacts) and review_head_matches?(payload, current_head_sha) do
      Enum.filter(artifacts, &(is_binary(&1) and String.trim(&1) != ""))
    else
      []
    end
  end

  defp review_package_artifact_paths(%ProgressEvent{}, _current_head_sha), do: []

  defp persisted_review_artifact?(artifacts, work_package_id, head_sha, path) do
    expected_id = review_artifact_id(work_package_id, head_sha, path)
    Enum.any?(artifacts, &(&1.id == expected_id and &1.kind == "review" and &1.path == path))
  end

  defp latest_current_head_sha(progress_events), do: latest_metadata_head_sha(progress_events, "branch", "attach_branch")

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

  defp incomplete_plan?(state) do
    plan_required?(state.work_package) and (Enum.any?(state.plan_nodes, &(&1.status not in @complete_plan_statuses)) or missing_meaningful_plan?(state))
  end

  defp missing_meaningful_plan?(%{plan_nodes: []}), do: true
  defp missing_meaningful_plan?(_state), do: false

  defp readiness_status_missing?(%WorkPackage{} = work_package) do
    if ci_waiting_required?(work_package) do
      work_package.status != "ci_waiting"
    else
      work_package.status not in ["reviewing", "ci_waiting"]
    end
  end

  defp readiness_status_gate(%WorkPackage{} = work_package), do: if(ci_waiting_required?(work_package), do: "status_ci_waiting", else: "status_reviewing")
  defp ci_waiting_required?(%WorkPackage{} = work_package), do: required_gate?(work_package, "ci_waiting")

  defp plan_required?(%WorkPackage{} = work_package) do
    case LifecycleService.policy_for(work_package) do
      {:ok, policy} -> get_in(policy, [:constraints, :planning_depth]) == "package"
      {:error, _reason} -> true
    end
  end

  defp acceptance_missing?(state) do
    required_gate?(state.work_package, "package_acceptance") and not acceptance_recorded?(state.progress_events)
  end

  defp tests_missing?(state) do
    required_gate?(state.work_package, "focused_tests") and not tests_recorded?(state)
  end

  defp required_gate?(%WorkPackage{} = work_package, gate) do
    case LifecycleService.policy_for(work_package) do
      {:ok, policy} -> gate in Map.get(policy, :required_gates, [])
      {:error, _reason} -> false
    end
  end

  defp acceptance_recorded?(progress_events) do
    current_head_sha = latest_current_head_sha(progress_events)

    case latest_review_package_event(progress_events, current_head_sha) do
      %ProgressEvent{payload: payload} when is_map(payload) -> Map.get(payload, "acceptance_criteria_met") == true
      _event -> false
    end
  end

  defp tests_recorded?(state) do
    if merge_required?(state.work_package) do
      review_package_tests_recorded?(state.progress_events)
    else
      review_package_tests_recorded?(state) or progress_status_recorded?(state.progress_events, "tests_passed")
    end
  end

  defp review_package_tests_recorded?(progress_events) when is_list(progress_events) do
    review_package_tests_recorded?(progress_events, latest_current_head_sha(progress_events))
  end

  defp review_package_tests_recorded?(%{progress_events: progress_events} = state) do
    review_package_tests_recorded?(progress_events, review_head_sha_for_readiness(state))
  end

  defp review_package_tests_recorded?(progress_events, readiness_head_sha) do
    readiness_head_sha = normalize_review_readiness_head_sha(readiness_head_sha)

    case latest_review_package_event(progress_events, readiness_head_sha) do
      %ProgressEvent{payload: payload} when is_map(payload) ->
        tests = Map.get(payload, "tests")
        is_list(tests) and Enum.any?(tests, &(is_binary(&1) and String.trim(&1) != ""))

      _event ->
        false
    end
  end

  defp review_head_sha_for_readiness(%{work_package: %WorkPackage{} = work_package, progress_events: progress_events}) do
    current_head_sha = latest_current_head_sha(progress_events)

    cond do
      is_binary(current_head_sha) -> current_head_sha
      merge_required?(work_package) -> nil
      true -> :any_head
    end
  end

  defp normalize_review_readiness_head_sha(head_sha) when is_binary(head_sha), do: head_sha
  defp normalize_review_readiness_head_sha(:any_head), do: :any_head
  defp normalize_review_readiness_head_sha(_head_sha), do: nil

  defp progress_status_recorded?(progress_events, expected_status) do
    head_boundary_sequence = latest_branch_event_sequence(progress_events)
    statuses = [expected_status, failed_status(expected_status)]

    latest_generic_progress_status(progress_events, head_boundary_sequence, statuses) == expected_status
  end

  defp latest_generic_progress_status(progress_events, head_boundary_sequence, statuses) do
    statuses = MapSet.new(statuses)

    progress_events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{status: status} = event ->
        status = normalized_status(status)

        if generic_append_progress_event?(event) and progress_after_head_boundary?(event, head_boundary_sequence) and MapSet.member?(statuses, status) do
          status
        end

      _event ->
        nil
    end)
  end

  defp failed_status("tests_passed"), do: "tests_failed"
  defp failed_status(status), do: status <> "_failed"

  defp latest_branch_event_sequence(progress_events) do
    progress_events
    |> Enum.reverse()
    |> Enum.find(&payload_type?(&1, "branch", "attach_branch"))
    |> case do
      %ProgressEvent{sequence: sequence} when is_integer(sequence) -> sequence
      _event -> nil
    end
  end

  defp progress_after_head_boundary?(%ProgressEvent{}, nil), do: true
  defp progress_after_head_boundary?(%ProgressEvent{sequence: sequence}, boundary_sequence) when is_integer(sequence), do: sequence > boundary_sequence
  defp progress_after_head_boundary?(%ProgressEvent{}, _boundary_sequence), do: false
  defp normalized_status(status) when is_binary(status), do: status |> String.trim() |> String.downcase()
  defp normalized_status(_status), do: ""
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
  defp metadata_tool("review_package"), do: "submit_review_package"
  defp head_sha_matches?(left, right), do: PullRequest.head_sha_matches?(left, right)

  defp payload_type?(%ProgressEvent{payload: payload}, type, source_tools) when is_map(payload) and is_list(source_tools) do
    Map.get(payload, "type") == type and Map.get(payload, "source_tool") in source_tools
  end

  defp payload_type?(%ProgressEvent{payload: payload}, type, source_tool) when is_map(payload) do
    Map.get(payload, "type") == type and Map.get(payload, "source_tool") == source_tool
  end

  defp payload_type?(%ProgressEvent{}, _type, _source_tool), do: false

  defp generic_append_progress_event?(%ProgressEvent{payload: payload}) when is_map(payload), do: Map.get(payload, "source_tool") == nil
  defp generic_append_progress_event?(%ProgressEvent{payload: nil}), do: true
  defp generic_append_progress_event?(%ProgressEvent{}), do: false

  defp recommendation_artifact_recorded?(artifacts, work_package_id) do
    artifact_id = ProgressEvents.recommendation_artifact_id(work_package_id)

    Enum.any?(
      artifacts,
      &(&1.id == artifact_id and &1.work_package_id == work_package_id and &1.path == "recommendation.md" and
          &1.title == "Investigation recommendation" and &1.kind == "recommendation")
    )
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

  defp require_phase_child_file_scope(%WorkPackage{} = child, %WorkPackage{} = anchor) do
    with {:ok, anchor_globs} <- normalize_child_scope_globs(anchor.allowed_file_globs || []),
         {:ok, child_globs} <- normalize_child_scope_globs(child.allowed_file_globs || []),
         :ok <- require_child_file_scope_present(child_globs),
         :ok <- reject_overbroad_child_globs(child_globs) do
      require_child_globs_within_anchor(child_globs, anchor_globs)
    end
  end

  defp require_child_file_scope_present([]), do: {:tool_error, "missing_allowed_file_globs"}
  defp require_child_file_scope_present(_globs), do: :ok

  defp reject_overbroad_child_globs(globs) do
    if Enum.any?(globs, &ScopeGuard.overbroad_glob?/1) do
      {:tool_error, "overbroad_allowed_file_globs"}
    else
      :ok
    end
  end

  defp require_child_globs_within_anchor(_child_globs, []), do: :ok

  defp require_child_globs_within_anchor(child_globs, anchor_globs) do
    if Enum.all?(child_globs, &glob_within_any_anchor?(&1, anchor_globs)) do
      :ok
    else
      {:tool_error, "child_scope_outside_phase"}
    end
  end

  defp glob_within_any_anchor?(child_glob, anchor_globs), do: Enum.any?(anchor_globs, &glob_within_anchor?(child_glob, &1))

  defp glob_within_anchor?(child_glob, anchor_glob) do
    with {:ok, child_segments} <- child_glob_segments(child_glob),
         {:ok, anchor_segments} <- child_glob_segments(anchor_glob) do
      glob_segments_within?(child_segments, anchor_segments)
    else
      {:tool_error, _reason} -> false
    end
  end

  defp child_glob_segments(glob) do
    glob = normalize_child_glob(glob)

    cond do
      glob == "" -> {:tool_error, "missing_allowed_file_globs"}
      traversal_glob?(glob) -> {:tool_error, "path_traversal_allowed_file_globs"}
      encoded_separator_glob?(glob) -> {:tool_error, "invalid_allowed_file_globs"}
      true -> {:ok, String.split(glob, "/", trim: true)}
    end
  end

  defp glob_segments_within?([], []), do: true
  defp glob_segments_within?([], _anchor_segments), do: false
  defp glob_segments_within?(_child_segments, []), do: false
  defp glob_segments_within?(child_segments, ["**"]), do: not Enum.any?(child_segments, &traversal_segment?/1)
  defp glob_segments_within?(["**" | child_tail], ["**" | anchor_tail]), do: glob_segments_within?(child_tail, ["**" | anchor_tail])

  defp glob_segments_within?([_child_head | child_tail] = child_segments, ["**" | anchor_tail]) do
    glob_segments_within?(child_segments, anchor_tail) or glob_segments_within?(child_tail, ["**" | anchor_tail])
  end

  defp glob_segments_within?(["**" | _child_tail], [_anchor_head | _anchor_tail]), do: false

  defp glob_segments_within?([child_head | child_tail], [anchor_head | anchor_tail]) do
    segment_within_anchor?(child_head, anchor_head) and glob_segments_within?(child_tail, anchor_tail)
  end

  defp segment_within_anchor?(child_segment, anchor_segment) do
    cond do
      child_segment == anchor_segment -> true
      anchor_segment == "*" -> child_segment != "**"
      child_segment == "**" -> false
      literal_glob?(child_segment) -> ScopeGuard.glob_match?(anchor_segment, child_segment)
      simple_star_segment_subset?(child_segment, anchor_segment) -> true
      true -> false
    end
  end

  defp literal_glob?(glob), do: not String.contains?(glob, ["*", "?", "["])

  defp simple_star_segment_subset?(child_segment, anchor_segment) do
    with {:ok, {anchor_prefix, anchor_suffix}} <- simple_star_bounds(anchor_segment),
         {child_prefix, child_suffix} <- segment_literal_bounds(child_segment) do
      String.starts_with?(child_prefix, anchor_prefix) and String.ends_with?(child_suffix, anchor_suffix)
    else
      :error -> false
    end
  end

  defp simple_star_bounds(segment) do
    cond do
      String.contains?(segment, ["?", "["]) -> :error
      segment |> String.graphemes() |> Enum.count(&(&1 == "*")) != 1 -> :error
      true -> {:ok, segment |> String.split("*", parts: 2) |> List.to_tuple()}
    end
  end

  defp segment_literal_bounds(segment) do
    tokens = segment_tokens(String.graphemes(segment), [])

    prefix =
      tokens
      |> Enum.take_while(&match?({:literal, _char}, &1))
      |> literal_token_string()

    suffix =
      tokens
      |> Enum.reverse()
      |> Enum.take_while(&match?({:literal, _char}, &1))
      |> Enum.reverse()
      |> literal_token_string()

    {prefix, suffix}
  end

  defp segment_tokens([], acc), do: Enum.reverse(acc)
  defp segment_tokens(["*" | rest], acc), do: segment_tokens(rest, [:wildcard | acc])
  defp segment_tokens(["?" | rest], acc), do: segment_tokens(rest, [:wildcard | acc])

  defp segment_tokens(["[" | rest], acc) do
    case drop_character_class(rest, false) do
      {:ok, rest} -> segment_tokens(rest, [:wildcard | acc])
      :error -> segment_tokens(rest, [{:literal, "["} | acc])
    end
  end

  defp segment_tokens([char | rest], acc), do: segment_tokens(rest, [{:literal, char} | acc])
  defp drop_character_class([], _has_content?), do: :error
  defp drop_character_class(["]" | _rest], false), do: :error
  defp drop_character_class(["]" | rest], true), do: {:ok, rest}
  defp drop_character_class([_char | rest], _has_content?), do: drop_character_class(rest, true)
  defp literal_token_string(tokens), do: Enum.map_join(tokens, "", fn {:literal, char} -> char end)

  defp normalize_child_scope_globs(globs) when is_list(globs) do
    normalized_globs =
      globs
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&normalize_child_glob/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      Enum.any?(normalized_globs, &traversal_glob?/1) -> {:tool_error, "path_traversal_allowed_file_globs"}
      Enum.any?(normalized_globs, &encoded_separator_glob?/1) -> {:tool_error, "invalid_allowed_file_globs"}
      true -> {:ok, normalized_globs}
    end
  end

  defp normalize_child_scope_globs(_globs), do: {:ok, []}

  defp normalize_child_glob(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.replace(~r/\A\.\//, "")
  end

  defp normalize_child_glob(_value), do: ""

  defp traversal_glob?(glob) when is_binary(glob) do
    glob
    |> String.split("/", trim: true)
    |> Enum.any?(&traversal_segment?/1)
  end

  defp traversal_glob?(_glob), do: false

  defp encoded_separator_glob?(glob) when is_binary(glob) do
    glob
    |> String.split("/", trim: true)
    |> Enum.any?(&encoded_separator_segment?/1)
  end

  defp encoded_separator_glob?(_glob), do: false

  defp encoded_separator_segment?(segment) when is_binary(segment) do
    segment
    |> String.trim()
    |> String.downcase()
    |> encoded_separator_segment?(0)
  end

  defp encoded_separator_segment?(_segment), do: false

  defp encoded_separator_segment?(segment, depth) do
    cond do
      String.contains?(segment, ["/", "\\"]) ->
        true

      depth >= 3 ->
        false

      true ->
        decoded_segment = URI.decode(segment)
        decoded_segment != segment and encoded_separator_segment?(decoded_segment, depth + 1)
    end
  rescue
    ArgumentError -> false
  end

  defp traversal_segment?(segment) when is_binary(segment) do
    segment
    |> String.trim()
    |> String.downcase()
    |> traversal_segment?(0)
  end

  defp traversal_segment?(_segment), do: false

  defp traversal_segment?(segment, depth) do
    cond do
      segment in [".", ".."] ->
        true

      segment |> path_separator_segments() |> Enum.any?(&(&1 in [".", ".."])) ->
        true

      depth >= 3 ->
        false

      true ->
        decoded_segment = segment |> URI.decode() |> String.replace("\\", "/")
        decoded_segment != segment and traversal_segment?(decoded_segment, depth + 1)
    end
  rescue
    ArgumentError -> false
  end

  defp path_separator_segments(segment) do
    segment
    |> String.replace("\\", "/")
    |> String.split("/", trim: true)
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

  defp required_list(arguments, key) do
    case Map.get(arguments, key) do
      [_head | _tail] = value -> {:ok, value}
      nil -> {:tool_error, "missing_#{key}"}
      [] -> {:tool_error, "missing_#{key}"}
      _value -> {:tool_error, "invalid_#{key}"}
    end
  end

  defp required_string_list(arguments, key) do
    with {:ok, values} <- required_list(arguments, key) do
      if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
        {:ok, Enum.map(values, &String.trim/1)}
      else
        {:tool_error, "invalid_#{key}"}
      end
    end
  end

  defp optional_boolean(arguments, key, default) do
    case Map.fetch(arguments, key) do
      {:ok, value} when is_boolean(value) -> {:ok, value}
      {:ok, _value} -> {:tool_error, "invalid_#{key}"}
      :error -> {:ok, default}
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
