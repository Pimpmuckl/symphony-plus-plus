defmodule SymphonyElixir.SymphonyPlusPlus.MCP.GuidanceTools do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_argument: 3,
      optional_object_argument: 2,
      optional_string_argument: 2,
      optional_string_argument: 3,
      required_argument: 2
    ]

  import SymphonyElixir.SymphonyPlusPlus.MCP.Payloads,
    only: [
      guidance_request_cards: 1,
      guidance_request_payload: 1,
      optional_payload: 1
    ]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.ActorResolver
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Service, as: GuidanceRequestService
  alias SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Auth,
    Config,
    CurrentWorkRequest,
    ProgressEvents,
    Session,
    ToolResult,
    WorkRequestScope
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff

  @typep mcp_tool_result :: {:ok, map()} | {:error, integer(), String.t(), map()}

  @spec call(String.t(), Config.t(), Session.t() | nil, map()) :: mcp_tool_result()
  def call("resolve_blocker", %Config{} = config, %Session{assignment: %{grant_role: "architect"}} = session, arguments) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_package_id} <- optional_string_argument(arguments, "work_package_id", Session.work_package_id(session)),
         {:ok, blocker_id} <- required_argument(arguments, "blocker_id"),
         {:ok, resolution} <- required_argument(arguments, "resolution"),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments),
         {:ok, actor} <- actor_for_package_resource(config.repo, session, :blocker, work_package_id),
         :ok <- PlanningService.authorize_package_action(config.repo, actor, :blocker_resolve, work_package_id, :blocker),
         attrs = %{
           "summary" => summary,
           "body" => optional_argument(arguments, "body", nil),
           "status" => optional_argument(arguments, "status", "resolved"),
           "idempotency_key" => ["resolve_blocker", work_package_id, String.trim(idempotency_key)] |> Enum.join(":"),
           "payload" =>
             Map.merge(caller_payload, %{
               "type" => "blocker",
               "source_tool" => "resolve_blocker",
               "blocker_id" => blocker_id,
               "resolution" => resolution,
               "active" => false
             })
         },
         {:ok, event} <- PlanningRepository.append_audit_progress_event_for_work_package(config.repo, session.assignment, work_package_id, attrs) do
      {:ok, ToolResult.tool_result(%{"progress_event" => ProgressEvents.payload(event)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "resolve_blocker", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "resolve_blocker")
    end
  end

  def call("resolve_blocker", %Config{} = config, %Session{} = session, arguments) do
    with {:ok, blocker_id} <- required_argument(arguments, "blocker_id"),
         {:ok, resolution} <- required_argument(arguments, "resolution") do
      append_scoped_progress(config.repo, session, arguments, "resolve_blocker", %{
        "type" => "blocker",
        "source_tool" => "resolve_blocker",
        "blocker_id" => blocker_id,
        "resolution" => resolution,
        "active" => false
      })
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "resolve_blocker", "reason" => reason}}
    end
  end

  def call("list_guidance_requests", %Config{} = config, session, arguments) do
    with {:ok, session} <- architect_session(config.repo, session, "read:guidance_request"),
         {:ok, status} <- optional_guidance_request_status(arguments),
         {:ok, work_package_id} <- optional_string_argument(arguments, "work_package_id"),
         {:ok, requested_work_request_id} <- optional_string_argument(arguments, "work_request_id"),
         {:ok, work_request_id} <-
           guidance_work_request_id_argument(requested_work_request_id, session, work_package_id),
         :ok <- WorkRequestScope.maybe_require_guidance_work_request_filter_scope(config.repo, session, requested_work_request_id),
         {:ok, filters, scope} <- WorkRequestScope.scoped_guidance_request_filters(config.repo, session),
         {:ok, filters} <- guidance_request_list_filters(config.repo, filters, status, work_package_id, work_request_id),
         {:ok, guidance_requests} <- GuidanceRequestService.list_visible_to_architect(config.repo, filters) do
      cards = guidance_request_cards(guidance_requests)

      payload = %{
        "guidance_requests" => cards,
        "total_count" => length(cards),
        "scope" => scope,
        "filters" => guidance_request_filter_payload(status, work_package_id, work_request_id)
      }

      {:ok, ToolResult.architect_agent_tool_result(payload, :guidance_request_list)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "list_guidance_requests", "reason" => reason}}
      {:error, :not_found} -> not_found_error("list_guidance_requests")
      {:error, reason} -> architect_error(reason, "list_guidance_requests")
    end
  end

  def call("answer_guidance_request", %Config{} = config, session, arguments) do
    with {:ok, session} <- architect_session(config.repo, session, "write:guidance_request"),
         {:ok, guidance_request_id} <- required_argument(arguments, "guidance_request_id"),
         {:ok, answer} <- required_argument(arguments, "answer"),
         {:ok, answered_by} <- optional_string_argument(arguments, "answered_by", session_claimed_by(session)),
         {:ok, filters, scope} <- WorkRequestScope.scoped_guidance_request_filters(config.repo, session),
         {:ok, visible_guidance_request} <- GuidanceRequestService.get_visible_to_architect(config.repo, guidance_request_id, filters),
         :ok <- authorize_guidance_request_for_session(config.repo, session, :guidance_request_answer, visible_guidance_request),
         {:ok, guidance_request} <-
           GuidanceRequestService.answer(config.repo, guidance_request_id, %{
             "answer" => answer,
             "answered_by" => answered_by,
             "answered_at" => DateTime.utc_now(:microsecond)
           }) do
      {:ok,
       ToolResult.tool_result(%{
         "guidance_request" => guidance_request_payload(guidance_request),
         "scope" => scope,
         "status" => %{"guidance_request_status" => guidance_request.status}
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "answer_guidance_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("answer_guidance_request")
      {:error, reason} -> architect_error(reason, "answer_guidance_request")
    end
  end

  def call("escalate_guidance_request", %Config{} = config, session, arguments) do
    with {:ok, session} <- architect_session(config.repo, session, "write:guidance_request"),
         {:ok, guidance_request_id} <- required_argument(arguments, "guidance_request_id"),
         {:ok, reason} <- required_argument(arguments, "reason"),
         {:ok, recommended_language} <- required_argument(arguments, "recommended_language"),
         {:ok, decision_prompt} <- optional_decision_prompt_argument(arguments, "decision_prompt"),
         {:ok, result} <-
           escalate_guidance_request_transaction(
             config.repo,
             session,
             guidance_request_id,
             reason,
             recommended_language,
             decision_prompt
           ) do
      {:ok, ToolResult.tool_result(result)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "escalate_guidance_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("escalate_guidance_request")
      {:error, reason} -> architect_error(reason, "escalate_guidance_request")
    end
  end

  def call("create_guidance_request", %Config{} = config, session, arguments) do
    with {:ok, session} <- scoped_session(config.repo, session, arguments),
         {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, question} <- required_argument(arguments, "question"),
         {:ok, context} <- required_argument(arguments, "context"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, guidance_request} <-
           GuidanceRequestService.create_for_assignment(config.repo, session.assignment, %{
             "summary" => summary,
             "question" => question,
             "context" => context,
             "idempotency_key" => idempotency_key
           }) do
      {:ok, ToolResult.read_tool_result(%{"guidance_request" => guidance_request_payload(guidance_request)})}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "create_guidance_request", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "create_guidance_request")
    end
  end

  def call("read_guidance_request", %Config{} = config, session, arguments) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, guidance_request_id} <- required_argument(arguments, "guidance_request_id") do
      read_guidance_request_for_session(config.repo, session, guidance_request_id, arguments)
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_guidance_request", "reason" => reason}}
      {:error, reason} -> worker_error(reason, "read_guidance_request")
    end
  end

  defp optional_guidance_request_status(arguments) do
    case Map.fetch(arguments, "status") do
      :error ->
        {:ok, nil}

      {:ok, status} when is_binary(status) ->
        status = String.trim(status)

        if status in GuidanceRequest.statuses() do
          {:ok, status}
        else
          {:tool_error, "invalid_status"}
        end

      {:ok, _status} ->
        {:tool_error, "invalid_status"}
    end
  end

  defp guidance_request_list_filters(repo, filters, status, work_package_id, work_request_id) do
    with {:ok, filters} <- WorkRequestScope.maybe_put_work_request_guidance_filter(repo, filters, work_request_id) do
      {:ok,
       filters
       |> maybe_put_guidance_status_filter(status)
       |> maybe_put_guidance_work_package_filter(work_package_id)}
    end
  end

  defp guidance_work_request_id_argument(work_request_id, %Session{} = session, nil), do: infer_guidance_work_request_id(work_request_id, session)
  defp guidance_work_request_id_argument(work_request_id, %Session{}, _work_package_id), do: {:ok, work_request_id}

  defp infer_guidance_work_request_id(nil, %Session{} = session) do
    case CurrentWorkRequest.id_argument(%{}, session) do
      {:ok, work_request_id} -> {:ok, work_request_id}
      {:tool_error, _reason} -> {:ok, nil}
    end
  end

  defp infer_guidance_work_request_id(work_request_id, %Session{}), do: {:ok, work_request_id}

  defp maybe_put_guidance_status_filter(filters, nil), do: filters
  defp maybe_put_guidance_status_filter(filters, status) when is_binary(status), do: Map.put(filters, "status", status)
  defp maybe_put_guidance_work_package_filter(filters, nil), do: filters
  defp maybe_put_guidance_work_package_filter(filters, work_package_id), do: Map.put(filters, "work_package_id", work_package_id)

  defp guidance_request_filter_payload(status, work_package_id, work_request_id) do
    %{}
    |> optional_put("status", status)
    |> optional_put("work_package_id", work_package_id)
    |> optional_put("work_request_id", work_request_id)
  end

  defp read_guidance_request_for_session(
         repo,
         %Session{assignment: %{grant_role: "worker"}} = session,
         guidance_request_id,
         arguments
       ) do
    with {:ok, session} <- scoped_session(repo, session, arguments),
         {:ok, guidance_request} <-
           GuidanceRequestService.get_for_assignment(repo, session.assignment, guidance_request_id) do
      {:ok, ToolResult.read_tool_result(%{"guidance_request" => guidance_request_payload(guidance_request)})}
    else
      {:error, :not_found} -> not_found_error("read_guidance_request")
      {:error, {:authorization_policy_denied, %Decision{reason_code: "scope_mismatch"}}} -> not_found_error("read_guidance_request")
      {:error, reason} -> worker_error(reason, "read_guidance_request")
    end
  end

  defp read_guidance_request_for_session(repo, %Session{assignment: %{grant_role: "architect"}} = session, guidance_request_id, arguments) do
    with {:ok, session} <- architect_session(repo, session, "read:guidance_request"),
         {:ok, work_package_id} <- optional_string_argument(arguments, "work_package_id"),
         {:ok, filters, scope} <- WorkRequestScope.scoped_guidance_request_filters(repo, session),
         {:ok, guidance_request} <- GuidanceRequestService.get_visible_to_architect(repo, guidance_request_id, filters),
         :ok <- authorize_guidance_request_for_session(repo, session, :guidance_request_read, guidance_request),
         :ok <- require_guidance_request_work_package(guidance_request, work_package_id) do
      {:ok, ToolResult.read_tool_result(%{"guidance_request" => guidance_request_payload(guidance_request), "scope" => scope})}
    else
      {:error, :not_found} -> not_found_error("read_guidance_request")
      {:error, reason} -> architect_error(reason, "read_guidance_request")
    end
  end

  defp read_guidance_request_for_session(_repo, %Session{}, _guidance_request_id, _arguments) do
    auth_error({:unauthorized, :unsupported_grant_role}, "read_guidance_request")
  end

  defp require_guidance_request_work_package(%GuidanceRequest{}, nil), do: :ok
  defp require_guidance_request_work_package(%GuidanceRequest{work_package_id: work_package_id}, work_package_id), do: :ok
  defp require_guidance_request_work_package(%GuidanceRequest{}, _work_package_id), do: {:error, :not_found}

  defp escalate_guidance_request_transaction(
         repo,
         %Session{} = session,
         guidance_request_id,
         reason,
         recommended_language,
         decision_prompt
       ) do
    repo
    |> run_architect_transaction(fn ->
      with {:ok, filters, scope} <- WorkRequestScope.scoped_guidance_request_filters(repo, session),
           {:ok, guidance_request} <-
             GuidanceRequestService.get_visible_to_architect(repo, guidance_request_id, filters),
           :ok <- authorize_guidance_request_for_session(repo, session, :guidance_request_escalate, guidance_request),
           :ok <- lock_work_package(repo, guidance_request.work_package_id),
           blocker_id = guidance_request_blocker_id(guidance_request.id),
           {:ok, escalated} <-
             GuidanceRequestService.escalate_human_info_needed(repo, guidance_request.id, %{
               "human_info_reason" => reason,
               "recommended_language" => recommended_language,
               "decision_prompt" => decision_prompt,
               "blocker_id" => blocker_id
             }),
           {:ok, blocker_event} <-
             PlanningRepository.append_audit_progress_event_for_work_package(
               repo,
               session.assignment,
               guidance_request.work_package_id,
               guidance_request_blocker_attrs(escalated, reason, recommended_language, blocker_id)
             ) do
        {:ok,
         %{
           "guidance_request" => guidance_request_payload(escalated),
           "blocker" => %{
             "id" => blocker_id,
             "active" => true,
             "progress_event_id" => blocker_event.id,
             "recommended_language" => recommended_language
           },
           "scope" => scope,
           "status" => %{"guidance_request_status" => escalated.status}
         }}
      end
    end)
  end

  defp guidance_request_blocker_attrs(%GuidanceRequest{} = guidance_request, reason, recommended_language, blocker_id) do
    %{
      "summary" => "Human info needed for guidance request: #{guidance_request.summary}",
      "body" => "Reason: #{reason}\n\nRecommended language: #{recommended_language}",
      "status" => "blocked",
      "idempotency_key" => "guidance_request_human_info_needed:#{guidance_request.id}",
      "payload" => %{
        "type" => "blocker",
        "source_tool" => "report_blocker",
        "blocker_id" => blocker_id,
        "active" => true,
        "guidance_request_id" => guidance_request.id,
        "guidance_request_status" => guidance_request.status,
        "human_info_needed" => true,
        "reason" => reason,
        "recommended_language" => recommended_language
      }
    }
  end

  defp guidance_request_blocker_id(guidance_request_id), do: "guidance_request:#{guidance_request_id}"

  defp append_scoped_progress(repo, session, arguments, tool, payload) do
    with {:ok, session} <- scoped_session(repo, session, arguments),
         :ok <- authorize_current_package_policy(repo, session, :blocker_resolve, :blocker),
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

  defp architect_session(repo, session, capability) when is_binary(capability) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_architect_assignment(session.assignment),
         :ok <- require_architect_capabilities(repo, session.assignment, [capability]) do
      {:ok, session}
    end
  end

  defp require_architect_capabilities(repo, assignment, capabilities) do
    with {:ok, effective_assignment} <- effective_architect_assignment(repo, assignment) do
      require_architect_capabilities(effective_assignment, capabilities)
    end
  end

  defp require_architect_capabilities(assignment, capabilities) do
    Enum.reduce_while(capabilities, :ok, fn capability, :ok ->
      case require_architect_capability(assignment, capability) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp require_architect_capability(%{capabilities: capabilities}, capability) when is_list(capabilities) do
    if capability in capabilities, do: :ok, else: {:error, :insufficient_capability}
  end

  defp require_architect_capability(_assignment, _capability), do: {:error, :insufficient_capability}

  defp effective_architect_assignment(repo, %{grant_role: "architect", grant_id: grant_id} = assignment) do
    with {:ok, %AccessGrant{} = grant} <- AccessGrantRepository.get(repo, grant_id) do
      case ArchitectHandoff.handoff_phase_grant?(repo, grant) do
        {:ok, true} -> {:ok, %{assignment | capabilities: ArchitectHandoff.effective_capabilities(grant.capabilities)}}
        {:ok, false} -> {:ok, %{assignment | capabilities: grant.capabilities || []}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp require_worker_assignment(%{grant_role: "worker"}), do: :ok
  defp require_worker_assignment(_assignment), do: {:error, :worker_grant_required}
  defp require_architect_assignment(%{grant_role: "architect"}), do: :ok
  defp require_architect_assignment(_assignment), do: {:error, :architect_grant_required}

  defp authorize_guidance_request_for_session(repo, %Session{} = session, action, %GuidanceRequest{} = guidance_request) do
    GuidanceRequestService.authorize_for_assignment(repo, session.assignment, action, guidance_request)
  end

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp run_architect_transaction(repo, fun) do
    case repo.transaction(fn -> rollback_architect_transaction_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_architect_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_architect_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp optional_decision_prompt_argument(arguments, key) do
    with {:ok, prompt} <- optional_object_argument(arguments, key) do
      case HumanDecisionPrompt.normalize(prompt) do
        {:ok, normalized} -> {:ok, normalized}
        {:error, reason} -> {:tool_error, "#{key} #{HumanDecisionPrompt.error_message(reason)}"}
      end
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

  defp auth_error(:unauthorized, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}
  defp auth_error({:unauthorized, reason}, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}
  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)
  defp auth_error(:forbidden, resource), do: {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}
  defp service_error(_reason, resource), do: {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  defp not_found_error(tool), do: {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
