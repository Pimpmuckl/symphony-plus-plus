defmodule SymphonyElixir.SymphonyPlusPlus.MCP.WorkerTools do
  @moduledoc false

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_argument: 3,
      optional_string_argument: 2,
      required_argument: 2
    ]

  import SymphonyElixir.SymphonyPlusPlus.MCP.Payloads,
    only: [
      optional_payload: 1,
      work_package_payload: 1
    ]

  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.WorkerContext
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.ActorResolver
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.MergeReconciler
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.StateMachine

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    ArchitectDeliveryTools,
    Auth,
    Config,
    ErrorDetails,
    ProgressEvents,
    PullRequestMetadata,
    ReviewReadiness,
    Session,
    TaskPlanTools,
    ToolResult,
    WorktreeScope
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Renderer, as: PlanningRenderer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @tools [
    "get_current_assignment",
    "read_context",
    "read_task_plan",
    "update_task_plan",
    "append_finding",
    "append_progress",
    "set_status",
    "report_blocker",
    "request_scope_expansion",
    "attach_branch",
    "attach_pr",
    "sync_pr",
    "submit_review_package",
    "complete_review",
    "mark_ready"
  ]
  @terminal_work_package_statuses ["merged", "merged_into_phase", "closed", "abandoned"]
  @finding_replay_retry_attempts 50

  @typep result :: {:ok, map()} | {:error, integer(), String.t(), map()}

  @spec tools() :: [String.t()]
  def tools, do: @tools

  @spec call(String.t(), Config.t(), Session.t() | nil, map()) :: result()
  def call("get_current_assignment", %Config{} = config, session, _arguments) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_assignment_introspection(session.assignment) do
      {:ok, ToolResult.agent_tool_result(%{"assignment" => Session.public_assignment(session)})}
    else
      {:error, reason} -> worker_error(reason, "get_current_assignment")
    end
  end

  def call("read_context", %Config{} = config, session, _arguments) do
    read_current_virtual_file(config.repo, session, "context.md")
  end

  def call("read_task_plan", %Config{} = config, session, _arguments) do
    case TaskPlanTools.read_task_plan(config.repo, session) do
      {:error, reason} -> worker_error(reason, "read_task_plan.md")
      result -> result
    end
  end

  def call("update_task_plan", %Config{} = config, session, arguments) do
    case scoped_session(config.repo, session, arguments) do
      {:ok, session} ->
        case authorize_current_package_policy(config.repo, session, :task_plan_update, :task_plan) do
          :ok -> normalize_update_task_plan_result(TaskPlanTools.update_task_plan(config.repo, session, arguments))
          {:error, reason} -> worker_error(reason, "update_task_plan")
        end

      {:error, reason} ->
        worker_error(reason, "update_task_plan")
    end
  end

  def call("append_finding", %Config{} = config, session, arguments), do: append_finding_tool(config.repo, session, arguments)

  def call("append_progress", %Config{} = config, session, arguments) do
    append_scoped_progress(config.repo, session, arguments, "append_progress", %{})
  end

  def call("set_status", %Config{} = config, session, arguments) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, status} <- required_argument(arguments, "status"),
         {:ok, expected_status} <- required_argument(arguments, "expected_status"),
         {:ok, reason} <- optional_reason(arguments),
         :ok <- reject_ready_status(status),
         {:ok, blocker_closeout_plan} <- maybe_prepare_work_package_status_blocker_closeout(config.repo, session, status, arguments),
         {:ok, {work_package, blocker_closeout}} <- set_status_transaction(config.repo, session, expected_status, status, reason, blocker_closeout_plan) do
      {:ok, ToolResult.tool_result(%{"work_package" => work_package_payload(work_package), "blocker_closeout" => blocker_closeout})}
    else
      {:tool_error, reason} -> invalid_params_error("set_status", reason)
      {:error, _code, _message, _data} = error -> error
      {:error, reason} -> worker_error(reason, "set_status")
    end
  end

  def call("report_blocker", %Config{} = config, session, arguments) do
    case optional_blocker_id(arguments) do
      {:ok, blocker_id} ->
        append_scoped_progress(config.repo, session, arguments, "report_blocker", %{
          "type" => "blocker",
          "source_tool" => "report_blocker",
          "blocker_id" => blocker_id,
          "active" => true
        })
        |> expose_blocker_id(blocker_id)

      {:error, reason} ->
        worker_error(reason, "report_blocker")
    end
  end

  def call("request_scope_expansion", %Config{} = config, session, arguments) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_worker_assignment(session.assignment),
         {:ok, payload} <- ProgressEvents.request_scope_expansion_payload(config.repo, session) do
      append_scoped_progress(config.repo, session, arguments, "request_scope_expansion", payload)
    else
      {:error, reason} -> worker_error(reason, "request_scope_expansion")
    end
  end

  def call("attach_branch", %Config{} = config, session, arguments) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         :ok <- authorize_current_package_policy(config.repo, session, :work_package_update, :work_package),
         {:ok, branch} <- attach_branch_argument(config.repo, session, arguments),
         {:ok, head_sha} <- required_argument(arguments, "head_sha") do
      ProgressEvents.append_metadata(config.repo, session, arguments, "attach_branch", "branch_attached", %{"type" => "branch", "branch" => branch, "head_sha" => head_sha})
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "attach_branch", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "attach_branch")
    end
  end

  def call("attach_pr", %Config{} = config, session, arguments) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         :ok <- authorize_current_package_policy(config.repo, session, :review_evidence_append, :review_evidence),
         {:ok, payload} <- PullRequestMetadata.payload(config.repo, session, arguments, "attach_pr") do
      append_pr_metadata(config.repo, session, arguments, "attach_pr", "pr_attached", payload)
      |> metadata_tool_response("attach_pr")
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "attach_pr", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "attach_pr")
    end
  end

  def call("sync_pr", %Config{} = config, session, arguments) do
    with {:ok, session} <- scoped_sync_pr_session(config.repo, session, arguments),
         :ok <- authorize_current_package_policy(config.repo, session, :review_evidence_append, :review_evidence),
         {:ok, payload} <- PullRequestMetadata.payload(config.repo, session, arguments, "sync_pr") do
      sync_pr(config.repo, session, arguments, payload)
      |> metadata_tool_response("sync_pr")
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "sync_pr", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "sync_pr")
    end
  end

  def call("submit_review_package", %Config{} = config, session, arguments) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         :ok <- authorize_current_package_policy(config.repo, session, :review_evidence_append, :review_evidence),
         {:ok, result} <- ReviewReadiness.submit_review_package(config.repo, session, arguments) do
      {:ok, result}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "submit_review_package", "reason" => reason}}
      {:error, _code, _message, _data} = error -> error
      {:error, reason} -> worker_error(reason, "submit_review_package")
    end
  end

  def call("complete_review", %Config{} = config, session, arguments) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         :ok <- authorize_current_package_policy(config.repo, session, :review_evidence_append, :review_evidence),
         {:ok, result} <- ReviewReadiness.complete_review(config.repo, session, arguments) do
      {:ok, result}
    else
      {:tool_error, reason} -> invalid_params_error("complete_review", reason)
      {:error, _code, _message, _data} = error -> error
      {:error, reason} -> worker_error(reason, "complete_review")
    end
  end

  def call("mark_ready", %Config{} = config, session, arguments) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- require_worker_assignment(session.assignment),
         {:ok, blocker_closeout_plan} <- ArchitectDeliveryTools.prepare_scoped_blocker_closeout(config.repo, session, [Session.work_package_id(session)], arguments, "mark_ready"),
         {:ok, {work_package, blocker_closeout, warnings}} <-
           ReviewReadiness.mark_ready(config.repo, session, blocker_closeout_plan, &ArchitectDeliveryTools.apply_prepared_blocker_closeout/3) do
      {:ok,
       ToolResult.tool_result(
         %{"work_package" => work_package_payload(work_package), "ready" => true, "blocker_closeout" => blocker_closeout}
         |> ReviewReadiness.maybe_put_readiness_warnings(warnings)
       )}
    else
      {:tool_error, reason} ->
        invalid_params_error("mark_ready", reason)

      {:error, {:readiness_failed, missing, reasons, warnings}} ->
        {:error, -32_602, "Invalid params",
         %{"tool" => "mark_ready", "reason" => "readiness_failed", "missing" => missing, "reasons" => reasons}
         |> ReviewReadiness.maybe_put_readiness_warnings(warnings)}

      {:error, {:readiness_failed, missing, reasons}} ->
        {:error, -32_602, "Invalid params", %{"tool" => "mark_ready", "reason" => "readiness_failed", "missing" => missing, "reasons" => reasons}}

      {:error, {:readiness_failed, missing}} ->
        {:error, -32_602, "Invalid params", %{"tool" => "mark_ready", "reason" => "readiness_failed", "missing" => missing}}

      {:error, reason} ->
        worker_error(reason, "mark_ready")
    end
  end

  defp append_finding_tool(repo, %Session{} = session, arguments) do
    with {:ok, session} <- scoped_session(repo, session, arguments),
         :ok <- authorize_current_package_policy(repo, session, :finding_append, :finding),
         {:ok, title} <- required_argument(arguments, "title"),
         {:ok, body} <- required_argument(arguments, "body"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         idempotency_key = String.trim(idempotency_key),
         {:ok, finding_id} <- optional_finding_id(arguments, session, idempotency_key),
         attrs = %{
           "id" => finding_id,
           "work_package_id" => Session.work_package_id(session),
           "title" => title,
           "body" => body,
           "severity" => optional_argument(arguments, "severity", "info"),
           "idempotency_key" => idempotency_key,
           "access_grant_id" => session.assignment.grant_id,
           "caller_supplied_id" => Map.has_key?(arguments, "id")
         },
         {:ok, finding} <- append_authenticated_idempotent_finding(repo, session, finding_id, attrs) do
      {:ok, ToolResult.agent_tool_result(%{"finding" => %{"id" => finding.id, "title" => finding.title, "severity" => finding.severity}})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "append_finding", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "append_finding")
    end
  end

  defp read_current_virtual_file(repo, session, file_name) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_worker_assignment(session.assignment),
         work_package_id = Session.work_package_id(session),
         uri = "sympp://work-packages/#{work_package_id}/#{file_name}",
         {:ok, state} <- PlanningRepository.get_render_state(repo, work_package_id),
         {:ok, markdown} <- PlanningRenderer.render_state(state, file_name) do
      {:ok,
       ToolResult.agent_tool_result(%{"uri" => uri, "text" => markdown}, fn ->
         {:ok, toon} = WorkerContext.encode_virtual_file(state, file_name, uri: uri)
         toon
       end)}
    else
      {:error, reason} -> worker_error(reason, "read_#{file_name}")
    end
  end

  defp normalize_update_task_plan_result({:tool_error, reason}),
    do: invalid_params_error("update_task_plan", reason)

  defp normalize_update_task_plan_result({:error, reason}), do: worker_error(reason, "update_task_plan")
  defp normalize_update_task_plan_result(result), do: result

  defp maybe_prepare_work_package_status_blocker_closeout(repo, %Session{} = session, status, arguments)
       when status in @terminal_work_package_statuses do
    ArchitectDeliveryTools.prepare_scoped_blocker_closeout(
      repo,
      session,
      [Session.work_package_id(session)],
      arguments,
      "set_status"
    )
  end

  defp maybe_prepare_work_package_status_blocker_closeout(_repo, %Session{}, _status, _arguments), do: {:ok, :not_needed}

  defp append_pr_metadata(repo, %Session{} = session, arguments, tool, status, payload) do
    with {:ok, idempotency_key, attrs} <- ProgressEvents.metadata_attrs(session, arguments, tool, status, payload),
         {:ok, replay?} <- ProgressEvents.replay?(repo, session, idempotency_key),
         :ok <-
           PullRequestMetadata.validate_sync_target_unless_replay(
             repo,
             session,
             arguments,
             payload,
             tool,
             replay?
           ) do
      run_worker_transaction(repo, fn ->
        append_pr_metadata_event(repo, session, attrs, idempotency_key, tool, payload, replay?)
      end)
    end
  end

  defp sync_pr(repo, %Session{} = session, arguments, payload) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, Session.work_package_id(session)) do
      sync_pr_for_package(repo, session, work_package, arguments, payload)
    end
  end

  defp sync_pr_for_package(repo, session, %WorkPackage{status: status} = work_package, arguments, payload)
       when status in ["ready_for_merge", "ready_for_human_merge", "merged"] do
    with :ok <-
           PullRequestMetadata.validate_sync_target_unless_replay(
             repo,
             session,
             arguments,
             payload,
             "sync_pr",
             false
           ),
         {:ok, result} <- MergeReconciler.reconcile_work_package(repo, work_package.id, pr_payload: payload) do
      terminal_sync_result(repo, work_package.id, result)
    end
  end

  defp sync_pr_for_package(repo, session, %WorkPackage{}, arguments, payload),
    do: append_pr_metadata(repo, session, arguments, "sync_pr", "pr_synced", payload)

  defp terminal_sync_result(repo, work_package_id, %{status: status} = result) when status in ["merged", "already_merged"] do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
      {:ok, ToolResult.agent_tool_result(%{"work_package" => work_package_payload(work_package), "pr_sync" => stringify_keys(result)})}
    end
  end

  defp terminal_sync_result(_repo, _work_package_id, result) do
    data =
      result
      |> Map.take([:reason, :expected_repository, :actual_repository, :expected_base_branch, :actual_base_branch, :expected_head_sha, :actual_head_sha, :delivery_error])
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("tool", "sync_pr")
      |> Map.put_new("reason", "terminal_pr_sync_failed")

    {:error, -32_602, "Invalid params", data}
  end

  defp stringify_keys(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp append_pr_metadata_event(repo, session, attrs, idempotency_key, tool, payload, replay?) do
    with {:ok, event_result} <- ProgressEvents.append_or_replay(repo, session, attrs, idempotency_key, tool),
         :ok <- PullRequestMetadata.maybe_upsert_artifact(repo, session, payload, replay?) do
      {:ok, event_result}
    end
  end

  defp set_status_transaction(repo, %Session{} = session, expected_status, status, reason, blocker_closeout_plan) do
    repo
    |> run_worker_transaction(fn ->
      with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
           {:ok, state} <- PlanningRepository.get_state(repo, Session.work_package_id(session)),
           :ok <- require_expected_status(state.work_package, expected_status, session),
           :ok <- reject_architect_controlled_child(state.work_package, status),
           {:ok, _event} <- append_status_reason_event(repo, session, expected_status, status, reason),
           {:ok, work_package} <- transition_status(repo, state.work_package, status, session),
           {:ok, blocker_closeout} <-
             ArchitectDeliveryTools.apply_prepared_blocker_closeout(repo, session, blocker_closeout_plan) do
        {:ok, {work_package, blocker_closeout}}
      end
    end)
  end

  defp append_authenticated_idempotent_finding(repo, %Session{} = session, finding_id, attrs) do
    work_package_id = Session.work_package_id(session)

    transaction_fun = fn ->
      append_authenticated_idempotent_finding_tx(repo, session, work_package_id, finding_id, attrs)
    end

    case run_worker_transaction(repo, transaction_fun) do
      {:error, :finding_insert_conflict} ->
        replay_finding_after_insert_conflict(repo, session.assignment, work_package_id, finding_id, attrs)

      result ->
        result
    end
  end

  defp append_authenticated_idempotent_finding_tx(repo, %Session{} = session, work_package_id, finding_id, attrs) do
    with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
         {:error, :id_already_exists} <-
           repo |> PlanningRepository.list_findings(work_package_id) |> find_existing_finding(finding_id, attrs),
         {:error, :id_already_exists} <-
           repo
           |> PlanningRepository.list_findings(work_package_id)
           |> find_existing_finding_by_idempotency(attrs),
         :ok <- ProgressEvents.reject_ready_evidence_mutation(repo, session, "append_finding") do
      case PlanningRepository.append_finding(repo, attrs) do
        {:ok, finding} ->
          {:ok, finding}

        {:error, reason} when reason in [:id_already_exists, :idempotency_key_conflict] ->
          {:error, :finding_insert_conflict}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp replay_finding_after_insert_conflict(repo, assignment, work_package_id, finding_id, attrs) do
    with :ok <- PlanningService.require_valid_assignment(repo, assignment) do
      replay_attempts = finding_replay_retry_attempts()

      case find_existing_finding_with_retry(repo, work_package_id, finding_id, attrs, replay_attempts) do
        {:error, :id_already_exists} ->
          find_existing_finding_by_idempotency_with_retry(repo, work_package_id, attrs, replay_attempts)

        result ->
          result
      end
    end
  end

  defp find_existing_finding_with_retry(repo, work_package_id, finding_id, attrs, attempts_left) do
    retry_fun = fn ->
      find_existing_finding_with_retry(repo, work_package_id, finding_id, attrs, attempts_left - 1)
    end

    repo
    |> PlanningRepository.list_findings(work_package_id)
    |> find_existing_finding(finding_id, attrs)
    |> retry_finding_replay_read(retry_fun, attempts_left)
  end

  defp find_existing_finding_by_idempotency_with_retry(repo, work_package_id, attrs, attempts_left) do
    retry_fun = fn ->
      find_existing_finding_by_idempotency_with_retry(repo, work_package_id, attrs, attempts_left - 1)
    end

    repo
    |> PlanningRepository.list_findings(work_package_id)
    |> find_existing_finding_by_idempotency(attrs)
    |> retry_finding_replay_read(retry_fun, attempts_left)
  end

  defp retry_finding_replay_read({:error, reason}, retry_fun, attempts_left)
       when reason in [:id_already_exists, :database_busy] and attempts_left > 0 do
    Process.sleep(5)
    retry_fun.()
  end

  defp retry_finding_replay_read(result, _retry_fun, _attempts_left), do: result

  defp find_existing_finding({:ok, findings}, finding_id, attrs) do
    case Enum.find(findings, &(&1.id == finding_id)) do
      %{} = finding ->
        if finding_idempotency_match?(finding, attrs) do
          idempotent_finding_result(finding, attrs)
        else
          {:tool_error, "idempotency_conflict"}
        end

      nil ->
        {:error, :id_already_exists}
    end
  end

  defp find_existing_finding({:error, reason}, _finding_id, _attrs), do: {:error, reason}

  defp find_existing_finding_by_idempotency({:ok, findings}, attrs) do
    case Enum.find(findings, &finding_idempotency_match?(&1, attrs)) do
      %{} = finding -> idempotent_finding_result(finding, attrs)
      nil -> {:error, :id_already_exists}
    end
  end

  defp find_existing_finding_by_idempotency({:error, reason}, _attrs), do: {:error, reason}

  defp finding_idempotency_match?(finding, attrs), do: finding.idempotency_key == Map.get(attrs, "idempotency_key")

  defp idempotent_finding_result(finding, attrs) do
    fields = if Map.get(attrs, "caller_supplied_id"), do: ["id", "title", "body", "severity"], else: ["title", "body", "severity"]
    expected = Map.take(attrs, fields)
    actual = Map.take(%{"id" => finding.id, "title" => finding.title, "body" => finding.body, "severity" => finding.severity}, fields)

    if expected == actual, do: {:ok, finding}, else: {:tool_error, "idempotency_conflict"}
  end

  defp optional_finding_id(arguments, session, idempotency_key) do
    case Map.get(arguments, "id") do
      id when is_binary(id) ->
        case String.trim(id) do
          "" -> {:tool_error, "invalid_id"}
          trimmed -> {:ok, trimmed}
        end

      nil ->
        {:ok, generated_finding_id(session, idempotency_key)}

      _id ->
        {:tool_error, "invalid_id"}
    end
  end

  defp generated_finding_id(session, idempotency_key) do
    material = [session.assignment.work_package_id, session.assignment.grant_id, idempotency_key] |> Enum.join(":")
    "finding_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp finding_replay_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_finding_replay_retry_attempts, @finding_replay_retry_attempts)
    |> max(0)
  end

  defp append_scoped_progress(repo, session, arguments, tool, payload) do
    with {:ok, session} <- scoped_session(repo, session, arguments),
         {action, resource_type} <- progress_tool_policy(tool),
         :ok <- authorize_current_package_policy(repo, session, action, resource_type),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments) do
      idempotency_key = ProgressEvents.scoped_idempotency_key(tool, String.trim(idempotency_key), session)

      attrs = %{
        "summary" => summary,
        "body" => optional_argument(arguments, "body", nil),
        "status" => optional_argument(arguments, "status", "recorded"),
        "idempotency_key" => idempotency_key,
        "payload" => ProgressEvents.merge_payload(tool, caller_payload, payload)
      }

      ProgressEvents.append_or_replay(repo, session, attrs, idempotency_key, tool)
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
      {:error, reason} -> worker_error(reason, tool)
    end
  end

  defp append_status_reason_event(_repo, %Session{}, _expected_status, _status, nil), do: {:ok, nil}

  defp append_status_reason_event(repo, %Session{} = session, expected_status, status, reason) when is_binary(reason) do
    payload = %{"type" => "status_transition", "from_status" => expected_status, "to_status" => status}
    idempotency_payload = Map.put(payload, "reason_event_id", System.unique_integer([:positive, :monotonic]))

    append_scoped_progress(
      repo,
      session,
      %{
        "summary" => "Status changed to #{status}",
        "body" => reason,
        "status" => "status_changed",
        "idempotency_key" => ProgressEvents.metadata_idempotency_key(Map.put(idempotency_payload, "reason", reason))
      },
      "set_status",
      payload
    )
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
  defp rollback_worker_transaction_result(repo, {:error, code, message, data}), do: repo.rollback({:mcp_error, code, message, data})
  defp rollback_worker_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp attach_branch_argument(repo, %Session{} = session, arguments) do
    case optional_string_argument(arguments, "branch") do
      {:ok, nil} -> inferred_attach_branch(repo, session)
      result -> result
    end
  end

  defp inferred_attach_branch(repo, %Session{} = session) do
    with {:ok, %WorkPackage{} = work_package} <- WorkPackageRepository.get(repo, Session.work_package_id(session)) do
      case normalize_optional_value(work_package.branch_pattern) do
        nil -> {:tool_error, "missing_branch"}
        branch when is_binary(branch) -> inferred_literal_branch(branch)
      end
    end
  end

  defp inferred_literal_branch(branch),
    do: if(WorktreeScope.local_branch_template_pattern?(branch), do: {:tool_error, "missing_branch"}, else: {:ok, branch})

  defp scoped_session(repo, session, arguments) when is_map(arguments) do
    case Auth.require_session(session, repo) do
      {:ok, session} ->
        with :ok <- require_worker_assignment(session.assignment) do
          require_argument_scope(session, Map.get(arguments, "work_package_id"))
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scoped_sync_pr_session(repo, session, arguments) do
    case scoped_session(repo, session, arguments) do
      {:error, {:unauthorized, :work_package_terminal}} ->
        with {:ok, session} <- Auth.require_terminal_session(session, repo),
             :ok <- require_worker_assignment(session.assignment) do
          require_argument_scope(session, Map.get(arguments, "work_package_id"))
        end

      result ->
        result
    end
  end

  defp require_argument_scope(session, nil), do: {:ok, session}
  defp require_argument_scope(session, work_package_id) when work_package_id == session.assignment.work_package_id, do: {:ok, session}
  defp require_argument_scope(_session, _work_package_id), do: {:error, :forbidden}

  defp authorize_current_package_policy(repo, %Session{} = session, action, resource_type) do
    work_package_id = Session.work_package_id(session)

    with {:ok, actor} <- actor_for_package_resource(repo, session, resource_type, work_package_id) do
      case PlanningService.authorize_package_action(repo, actor, action, work_package_id, resource_type) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp actor_for_package_resource(repo, %Session{} = session, resource_type, work_package_id) do
    with {:ok, target} <- PlanningService.package_resource_target(repo, work_package_id, resource_type) do
      ActorResolver.from_session(session, PlanningService.package_surface_actor_opts(session.assignment, target))
    end
  end

  defp require_worker_assignment(%{grant_role: "worker"}), do: :ok
  defp require_worker_assignment(_assignment), do: {:error, :worker_grant_required}
  defp require_assignment_introspection(%{grant_role: grant_role}) when grant_role in ["worker", "architect"], do: :ok
  defp require_assignment_introspection(_assignment), do: {:error, :worker_grant_required}

  defp progress_tool_policy("report_blocker"), do: {:blocker_report, :blocker}
  defp progress_tool_policy("set_status"), do: {:work_package_update, :work_package}
  defp progress_tool_policy(_tool), do: {:progress_append, :progress}

  defp metadata_tool_response({:ok, _result} = result, _tool), do: result
  defp metadata_tool_response({:error, _code, _message, _data} = error, _tool), do: error
  defp metadata_tool_response({:tool_error, reason}, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
  defp metadata_tool_response({:error, reason}, tool), do: worker_error(reason, tool)

  defp reject_ready_status(status) when status in ["ready_for_merge", "ready_for_human_merge", "ready_for_architect_merge"], do: {:tool_error, "use_mark_ready"}
  defp reject_ready_status(_status), do: :ok

  defp require_expected_status(%WorkPackage{status: expected_status}, expected_status, %Session{}), do: :ok

  defp require_expected_status(%WorkPackage{} = work_package, _expected_status, %Session{} = session),
    do: lifecycle_conflict_error(:stale_status, work_package, session)

  defp transition_status(repo, %WorkPackage{} = work_package, status, %Session{} = session) do
    case LifecycleService.transition(repo, work_package, status, actor(session)) do
      {:error, reason} when reason in [:invalid_transition, :stale_status] ->
        lifecycle_conflict_error(reason, work_package, session)

      result ->
        result
    end
  end

  defp lifecycle_conflict_error(reason, %WorkPackage{} = work_package, %Session{} = session) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => "set_status",
       "reason" => reason_text(reason),
       "current_status" => work_package.status,
       "allowed_next_statuses" => Enum.filter(WorkPackage.statuses(), &(StateMachine.validate_transition(work_package, &1, actor(session)) == :ok))
     }}
  end

  defp reject_architect_controlled_child(%WorkPackage{kind: "phase_child", status: "merging_into_phase"}, "blocked"), do: :ok

  defp reject_architect_controlled_child(%WorkPackage{kind: "phase_child", status: status}, _next_status)
       when status in ["merging_into_phase", "merged_into_phase"],
       do: {:tool_error, "child_under_architect_control"}

  defp reject_architect_controlled_child(%WorkPackage{}, _next_status), do: :ok

  defp optional_reason(arguments) do
    case Map.get(arguments, "reason") do
      nil ->
        {:ok, nil}

      reason when is_binary(reason) ->
        case String.trim(reason) do
          "" -> {:ok, nil}
          trimmed -> {:ok, trimmed}
        end

      _reason ->
        {:tool_error, "invalid_reason"}
    end
  end

  defp optional_blocker_id(arguments) do
    default = Map.get(arguments, "idempotency_key")

    case Map.get(arguments, "blocker_id") do
      value when is_binary(value) -> {:ok, if(String.trim(value) == "", do: normalize_blocker_id(default), else: String.trim(value))}
      nil -> {:ok, normalize_blocker_id(default)}
      _value -> {:error, :invalid_blocker_id}
    end
  end

  defp normalize_blocker_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_blocker_id(value), do: value

  defp expose_blocker_id({:ok, %{"structuredContent" => structured_content}}, blocker_id) do
    {:ok, structured_content |> Map.put("blocker_id", blocker_id) |> ToolResult.agent_tool_result()}
  end

  defp expose_blocker_id(result, _blocker_id), do: result

  defp normalize_optional_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_value(nil), do: nil

  defp actor(%Session{} = session) do
    %{
      grant_id: session.assignment.grant_id,
      grant_role: session.assignment.grant_role,
      capabilities: session.assignment.capabilities,
      work_package_id: session.assignment.work_package_id
    }
  end

  defp worker_error(:unauthorized, resource), do: auth_error(:unauthorized, resource)
  defp worker_error({:unauthorized, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error(:expired, resource), do: auth_error({:unauthorized, :expired}, resource)
  defp worker_error(:assignment_revoked, resource), do: auth_error({:unauthorized, :revoked}, resource)
  defp worker_error(:assignment_mismatch, resource), do: auth_error({:unauthorized, :assignment_mismatch}, resource)
  defp worker_error(:worker_grant_required, resource), do: auth_error({:unauthorized, :worker_grant_required}, resource)
  defp worker_error({:authorization_policy_denied, %Decision{} = decision}, resource), do: MCPError.from_decision(decision, resource)
  defp worker_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp worker_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp worker_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp worker_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp worker_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp worker_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

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

  defp invalid_params_error(tool, {:invalid_enum, _field, _allowed_values} = reason),
    do: ErrorDetails.invalid_params_error(tool, reason)

  defp invalid_params_error(tool, reason), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp auth_error(:unauthorized, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}
  defp auth_error({:unauthorized, reason}, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}
  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)
  defp auth_error(:forbidden, resource), do: {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}
  defp service_error(_reason, resource), do: {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
