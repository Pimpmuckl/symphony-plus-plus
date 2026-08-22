defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ArchitectWorkRequestTools do
  @moduledoc false

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_positive_integer_argument: 2,
      optional_string_argument: 2,
      optional_string_argument: 3,
      required_argument: 2
    ]

  import SymphonyElixir.SymphonyPlusPlus.MCP.Payloads,
    only: [
      dispatch_work_package_result_payload: 2,
      json_safe_payload: 1,
      worktree_lifecycle_payload: 3
    ]

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.BranchPattern

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    ArchitectDeliveryTools,
    Auth,
    Config,
    CurrentWorkRequest,
    HandoffDatabase,
    LocalTrustedTools,
    Session,
    ToolCatalog,
    ToolResult,
    WorkRequestPayloads,
    WorkRequestScope,
    WorktreeScope
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Service, as: WorkPackageService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDispatch
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @tools [
    "list_work_requests",
    "read_work_request",
    "read_plan",
    "read_delivery_board",
    "set_work_request_status",
    "answer_question",
    "answer_question_and_record_decision",
    "close_question",
    "dispatch_work_package",
    "prepare_work_package_worktree",
    "cleanup_work_package_worktree"
  ]
  @work_request_product_tree_views ToolCatalog.work_request_product_tree_views()
  @default_list_limit 50
  @max_list_limit 200
  @list_candidate_batch_size @max_list_limit + 1
  @max_list_candidate_batches 3

  @spec tools() :: [String.t()]
  def tools, do: @tools

  @spec call(String.t(), Config.t(), Session.t() | nil, map(), keyword()) ::
          {:ok, term()} | {:error, integer(), String.t(), map()}
  def call(name, %Config{} = config, session, arguments, opts \\ []) when name in @tools do
    call_tool(name, config, session, arguments, opts)
  end

  @spec scoped_worktree_work_package(module(), Session.t(), String.t()) ::
          {:ok, WorkPackage.t(), map()} | {:error, term()}
  def scoped_worktree_work_package(repo, %Session{} = session, work_package_id) do
    with {:ok, %WorkPackage{} = work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, filters, scope} <- WorkRequestScope.scoped_work_request_filters(repo, session),
         :ok <- require_worktree_work_package_scope(repo, work_package, filters) do
      {:ok, work_package, scope}
    else
      {:error, :forbidden} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp call_tool("list_work_requests", config, nil, arguments, opts) do
    with :ok <- authorize_local_trusted_work_request_read_tool_call(opts, "list_work_requests"),
         {:ok, status} <- optional_work_request_status(arguments),
         {:ok, pagination} <- list_pagination(arguments),
         filters = WorkRequestScope.work_request_list_filters(%{}, status),
         {:ok, work_requests, next_cursor} <-
           local_work_request_page(
             config.repo,
             WorkRequestScope.work_request_repository_filters(filters),
             pagination
           ) do
      cards = WorkRequestPayloads.work_request_cards(work_requests)

      {:ok,
       ToolResult.agent_tool_result(
         work_request_list_payload(
           cards,
           %{"visibility" => "local_ledger"},
           status,
           pagination.limit,
           next_cursor
         )
       )}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "list_work_requests", "reason" => reason}}
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "list_work_requests")
    end
  end

  defp call_tool("list_work_requests", config, session, arguments, _opts) do
    repo_scope_opts = WorkRequestScope.work_request_repo_scope_opts(config)

    with {:ok, session} <- Auth.require_session(session, config.repo),
         :ok <- authorize_list_work_requests_role(session, repo_scope_opts),
         {:ok, status} <- optional_work_request_status(arguments),
         {:ok, pagination} <- list_pagination(arguments),
         {:ok, filters, scope} <-
           WorkRequestScope.scoped_work_request_filters(config.repo, session, handoff_phase_scope?: false),
         policy_session = WorkRequestScope.read_scoped_work_request_session(config.repo, session, scope, :work_request_read),
         :ok <- WorkRequestScope.authorize_work_request_list_policy(policy_session, scope, "list_work_requests", repo_scope_opts),
         filters = WorkRequestScope.work_request_list_filters(filters, status),
         {:ok, work_requests, next_cursor} <-
           scoped_work_request_page(
             config.repo,
             WorkRequestScope.work_request_repository_filters(filters),
             filters,
             policy_session,
             repo_scope_opts,
             pagination
           ) do
      cards = WorkRequestPayloads.work_request_cards(work_requests)

      {:ok, ToolResult.agent_tool_result(work_request_list_payload(cards, scope, status, pagination.limit, next_cursor))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "list_work_requests", "reason" => reason}}
      {:error, reason} -> architect_error(reason, "list_work_requests")
    end
  end

  defp call_tool("read_work_request", config, nil, arguments, opts) do
    with :ok <- authorize_local_trusted_work_request_read_tool_call(opts, "read_work_request"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_request, _filters} <- WorkRequestScope.local_trusted_work_request_read_scope(config.repo, work_request_id),
         {:ok, payload} <- WorkRequestPayloads.work_request_detail(config.repo, work_request, []) do
      payload = Map.put(payload, "scope", WorkRequestPayloads.redacted_work_request_scope(work_request))
      {:ok, ToolResult.architect_agent_tool_result(payload, :work_request_read)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_work_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_work_request")
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "read_work_request")
    end
  end

  defp call_tool("read_work_request", config, %Session{} = session, arguments, _opts) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_request, _filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(
             config.repo,
             session,
             work_request_id,
             :work_request_read,
             "read_work_request",
             WorkRequestScope.work_request_repo_scope_opts(config)
           ),
         {:ok, payload} <- WorkRequestPayloads.work_request_detail(config.repo, work_request, []) do
      payload = Map.put(payload, "scope", scope)
      {:ok, ToolResult.architect_agent_tool_result(payload, :work_request_read)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_work_request", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_work_request")
      {:error, reason} -> architect_error(reason, "read_work_request")
    end
  end

  defp call_tool("read_plan", config, nil, arguments, opts) do
    with :ok <- authorize_local_trusted_work_request_read_tool_call(opts, "read_plan"),
         {:ok, work_request_id, view} <- read_plan_arguments(arguments),
         {:ok, work_request, scope} <- WorkRequestScope.local_trusted_work_request_read_scope(config.repo, work_request_id),
         {:ok, result} <- read_plan_result(config.repo, work_request, scope, scope, view) do
      {:ok, result}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_plan", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_plan")
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "read_plan")
    end
  end

  defp call_tool("read_plan", config, %Session{} = session, arguments, _opts) do
    repo_scope_opts = WorkRequestScope.work_request_repo_scope_opts(config)

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id, view} <- read_plan_arguments(arguments),
         {:ok, work_request, filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(
             config.repo,
             session,
             work_request_id,
             :work_request_read,
             "read_plan",
             repo_scope_opts
           ),
         {:ok, result} <- read_plan_result(config.repo, work_request, filters, scope, view, repo_scope_opts) do
      {:ok, result}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_plan", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_plan")
      {:error, reason} -> architect_error(reason, "read_plan")
    end
  end

  defp call_tool("read_delivery_board", config, %Session{} = session, arguments, _opts) do
    repo_scope_opts = WorkRequestScope.work_request_repo_scope_opts(config)

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, work_request, filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(
             config.repo,
             session,
             work_request_id,
             :delivery_board_read,
             "read_delivery_board",
             repo_scope_opts
           ),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(config.repo, work_request_id),
         {:ok, delivery_board} <- WorkRequestScope.scoped_delivery_board(config.repo, work_request, work_packages, filters, repo_scope_opts) do
      payload = %{
        "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
        "delivery_board" => WorkRequestPayloads.delivery_board(delivery_board),
        "scope" => scope
      }

      {:ok, ToolResult.architect_agent_tool_result(payload, :work_request_delivery_board)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_delivery_board", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_delivery_board")
      {:error, reason} -> architect_error(reason, "read_delivery_board")
    end
  end

  defp call_tool("read_delivery_board", config, nil, arguments, opts) do
    with :ok <- authorize_local_trusted_work_request_read_tool_call(opts, "read_delivery_board"),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, work_request, filters} <- WorkRequestScope.local_trusted_work_request_read_scope(config.repo, work_request_id),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(config.repo, work_request_id),
         {:ok, delivery_board} <- WorkRequestScope.scoped_delivery_board(config.repo, work_request, work_packages, filters) do
      payload = %{
        "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
        "delivery_board" => WorkRequestPayloads.delivery_board(delivery_board),
        "scope" => WorkRequestPayloads.redacted_work_request_scope(work_request)
      }

      {:ok, ToolResult.architect_agent_tool_result(payload, :work_request_delivery_board)}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "read_delivery_board", "reason" => reason}}
      {:error, :not_found} -> not_found_error("read_delivery_board")
      {:error, code, message, data} -> {:error, code, message, data}
      {:error, reason} -> architect_error(reason, "read_delivery_board")
    end
  end

  defp call_tool("set_work_request_status", config, session, arguments, _opts) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, next_status} <- required_argument(arguments, "next_status"),
         {:ok, _work_request, _filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, "set_work_request_status"),
         {:ok, updated_work_request} <- WorkRequestService.update_status(config.repo, work_request_id, current_status, next_status) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "scope" => scope,
         "status" => %{
           "previous_status" => current_status,
           "current_status" => updated_work_request.status
         }
       })}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "set_work_request_status", "reason" => reason}}
      {:error, :not_found} -> not_found_error("set_work_request_status")
      {:error, reason} -> architect_error(reason, "set_work_request_status")
    end
  end

  defp call_tool("answer_question", config, session, arguments, _opts) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, question_id} <- required_argument(arguments, "question_id"),
         {:ok, expected_question_status} <- expected_question_status_argument(arguments),
         {:ok, answer} <- required_argument(arguments, "answer"),
         {:ok, answered_by} <- optional_string_argument(arguments, "answered_by", session_claimed_by(session)),
         {:ok, _work_request, filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :question_answer, "answer_question"),
         {:ok, _question} <- WorkRequestScope.scoped_work_request_question(config.repo, work_request_id, question_id),
         {:ok, question_record} <-
           WorkRequestService.answer_question(config.repo, question_id, expected_question_status, %{
             "answer" => answer,
             "answered_by" => answered_by
           }),
         {:ok, updated_work_request} <- WorkRequestScope.scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "clarification_question" => WorkRequestPayloads.clarification_question(question_record),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "previous_question_status" => expected_question_status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> invalid_params_error("answer_question", reason)
      {:error, :not_found} -> not_found_error("answer_question")
      {:error, reason} -> architect_error(reason, "answer_question")
    end
  end

  defp call_tool("answer_question_and_record_decision", config, session, arguments, _opts) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, question_id} <- required_argument(arguments, "question_id"),
         {:ok, expected_question_status} <- expected_question_status_argument(arguments),
         {:ok, answer} <- required_argument(arguments, "answer"),
         {:ok, answered_by} <- optional_string_argument(arguments, "answered_by", session_claimed_by(session)),
         {:ok, source_type} <- required_argument(arguments, "source_type"),
         {:ok, decision} <- required_argument(arguments, "decision"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, scope_impact} <- required_argument(arguments, "scope_impact"),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", answered_by),
         {:ok, source_id} <- optional_string_argument(arguments, "source_id", question_id),
         {:ok, work_request, filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(
             config.repo,
             session,
             work_request_id,
             :question_answer,
             "answer_question_and_record_decision"
           ),
         :ok <-
           WorkRequestScope.authorize_work_request_policy(
             config.repo,
             session,
             :decision_record,
             work_request,
             "answer_question_and_record_decision"
           ),
         {:ok, _question} <- WorkRequestScope.scoped_work_request_question(config.repo, work_request_id, question_id),
         {:ok, %{decision: decision_record, question: question_record}} <-
           answer_question_and_record_decision_transaction(config.repo, work_request_id, question_id, expected_question_status, %{
             "answer" => answer,
             "answered_by" => answered_by,
             "source_type" => source_type,
             "source_id" => source_id,
             "decision" => decision,
             "rationale" => rationale,
             "scope_impact" => scope_impact,
             "created_by" => created_by
           }),
         {:ok, updated_work_request} <- WorkRequestScope.scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "clarification_question" => WorkRequestPayloads.clarification_question(question_record),
         "decision_log_entry" => WorkRequestPayloads.decision_log_entry(decision_record),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "previous_question_status" => expected_question_status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> invalid_params_error("answer_question_and_record_decision", reason)
      {:error, :not_found} -> not_found_error("answer_question_and_record_decision")
      {:error, reason} -> architect_error(reason, "answer_question_and_record_decision")
    end
  end

  defp call_tool("close_question", config, session, arguments, _opts) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, question_id} <- required_argument(arguments, "question_id"),
         {:ok, expected_question_status} <- expected_question_status_argument(arguments),
         {:ok, _work_request, filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :question_close, "close_question"),
         {:ok, _question} <- WorkRequestScope.scoped_work_request_question(config.repo, work_request_id, question_id),
         {:ok, question_record} <- WorkRequestService.close_question(config.repo, question_id, expected_question_status),
         {:ok, updated_work_request} <- WorkRequestScope.scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "clarification_question" => WorkRequestPayloads.clarification_question(question_record),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "previous_question_status" => expected_question_status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> invalid_params_error("close_question", reason)
      {:error, :not_found} -> not_found_error("close_question")
      {:error, reason} -> architect_error(reason, "close_question")
    end
  end

  defp call_tool("dispatch_work_package", config, session, arguments, _opts) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, claimed_by} <- optional_string_argument(arguments, "claimed_by", default_claimed_by(config)),
         {:ok, _work_request, work_package, _filters, scope} <-
           WorkRequestScope.authorized_work_package_scope(
             config.repo,
             session,
             work_request_id,
             work_package_id,
             :work_package_dispatch,
             "dispatch_work_package"
           ),
         :ok <- require_planned_dispatch_work_package(work_package),
         {:ok, handoff_opts} <- dispatch_work_package_bootstrap_opts(config, claimed_by),
         {:ok, dispatch} <- WorkPackageDispatch.dispatch(config.repo, work_request_id, work_package_id, handoff_opts) do
      {:ok, ToolResult.tool_result(dispatch_work_package_result_payload(dispatch, scope))}
    else
      {:tool_error, reason} -> invalid_params_error("dispatch_work_package", reason)
      {:error, :not_found} -> not_found_error("dispatch_work_package")
      {:error, reason} -> dispatch_work_package_error(reason)
    end
  end

  defp call_tool("prepare_work_package_worktree", config, session, arguments, _opts) do
    with {:ok, session} <- architect_session(config.repo, session, "dispatch:work_request"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, work_package, scope} <- scoped_worktree_work_package(config.repo, session, work_package_id),
         {:ok, explicit_root} <- optional_string_argument(arguments, "target_repo_root"),
         {:ok, target_repo_root} <- WorktreeScope.target_repo_root_argument(explicit_root, work_package, config),
         {:ok, branch_arg} <- optional_string_argument(arguments, "branch"),
         {:ok, branch} <- WorktreeScope.prepare_branch(work_package, branch_arg),
         :ok <- WorktreeScope.require_target_repo_root_scope(target_repo_root, work_package, config),
         {:ok, result} <-
           WorkPackageService.prepare_worktree(
             config.repo,
             work_package_id,
             %{
               "target_repo_root" => target_repo_root,
               "base_branch" => work_package.base_branch,
               "branch" => branch
             }
           ),
         {:ok, audit_event} <- append_worktree_lifecycle_audit(config.repo, session, work_package_id, "prepare_work_package_worktree", result) do
      {:ok, ToolResult.tool_result(worktree_lifecycle_payload(result, scope, audit_event))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "prepare_work_package_worktree", "reason" => reason}}
      {:error, :not_found} -> not_found_error("prepare_work_package_worktree")
      {:error, reason} -> architect_error(reason, "prepare_work_package_worktree")
    end
  end

  defp call_tool("cleanup_work_package_worktree", config, session, arguments, _opts) do
    with {:ok, session} <- architect_session(config.repo, session, "dispatch:work_request"),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, target_repo_root} <- optional_string_argument(arguments, "target_repo_root"),
         {:ok, work_package, scope} <- scoped_worktree_work_package(config.repo, session, work_package_id),
         {:ok, cleanup_target_repo_root} <-
           WorktreeScope.cleanup_target_repo_root(
             target_repo_root,
             work_package,
             config
           ),
         :ok <-
           WorktreeScope.require_cleanup_target_repo_root_scope(
             cleanup_target_repo_root,
             work_package,
             config
           ),
         {:ok, result} <-
           WorkPackageService.cleanup_worktree(
             config.repo,
             work_package_id,
             cleanup_worktree_opts(cleanup_target_repo_root)
           ),
         {:ok, _runtime_cleanup} <- ArchitectDeliveryTools.cleanup_worktree_runtime(config.repo, session, work_package),
         {:ok, audit_event} <- maybe_append_cleanup_worktree_audit(config.repo, session, work_package_id, result) do
      {:ok, ToolResult.tool_result(worktree_lifecycle_payload(result, scope, audit_event))}
    else
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => "cleanup_work_package_worktree", "reason" => reason}}
      {:error, :not_found} -> not_found_error("cleanup_work_package_worktree")
      {:error, reason} -> architect_error(reason, "cleanup_work_package_worktree")
    end
  end

  defp authorize_list_work_requests_role(%Session{assignment: %{grant_role: "architect"}}, _repo_scope_opts), do: :ok

  defp authorize_list_work_requests_role(%Session{} = session, repo_scope_opts) do
    WorkRequestScope.authorize_work_request_list_policy(
      session,
      %{"repo" => "role-boundary", "base_branch" => nil},
      "list_work_requests",
      repo_scope_opts
    )
  end

  defp authorize_local_trusted_work_request_read_tool_call(opts, tool) do
    opts
    |> Keyword.fetch!(:server)
    |> LocalTrustedTools.authorize(tool)
  end

  defp read_plan_arguments(arguments) do
    with {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, view} <- optional_product_tree_view(arguments) do
      {:ok, work_request_id, view}
    end
  end

  defp read_plan_result(
         repo,
         %WorkRequest{} = work_request,
         filters,
         scope,
         view,
         repo_scope_opts \\ []
       ) do
    case repo.transaction(fn -> read_plan_transaction(repo, work_request, filters, scope, view, repo_scope_opts) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_plan_transaction(repo, work_request, filters, scope, view, repo_scope_opts) do
    with {:ok, work_request} <- WorkRequestService.get(repo, work_request.id),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(repo, work_request.id),
         {:ok, delivery_board} <-
           WorkRequestScope.scoped_delivery_board(repo, work_request, work_packages, filters, Keyword.put(repo_scope_opts, :slice_projection, :operational_state)) do
      payload = WorkRequestPayloads.work_request_product_tree(repo, work_request, work_packages, delivery_board, view)
      payload = Map.put(payload, "scope", scope)
      ToolResult.architect_agent_tool_result(payload, :work_request_product_tree)
    else
      error -> repo.rollback(error)
    end
  end

  defp dispatch_work_package_bootstrap_opts(%Config{} = config, claimed_by) do
    with {:ok, database} <- HandoffDatabase.resolve(config.database, config.repo) do
      {:ok, [claimed_by: claimed_by, database: database]}
    end
  end

  defp cleanup_worktree_opts(nil), do: []
  defp cleanup_worktree_opts(target_repo_root), do: [target_repo_root: target_repo_root]

  defp require_planned_dispatch_work_package(%WorkPackage{status: "planned"}), do: :ok

  defp require_planned_dispatch_work_package(%WorkPackage{status: status}),
    do: {:error, {:invalid_work_package_status, status}}

  defp dispatch_work_package_error({:invalid_work_package_status, _status}) do
    {:error, -32_602, "Invalid params", %{"tool" => "dispatch_work_package", "reason" => "invalid_work_package_status"}}
  end

  defp dispatch_work_package_error({:work_package_scope_violation, errors}) do
    invalid_params_error("dispatch_work_package", {:work_package_scope_violation, errors})
  end

  defp dispatch_work_package_error({:execution_graph_cycle, cycles}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => "dispatch_work_package",
       "reason" => "execution_graph_cycle",
       "cycles" => cycles
     }}
  end

  defp dispatch_work_package_error({:unmet_work_package_dependencies, work_package_id, prerequisite_ids}) do
    reason = {:unmet_work_package_dependencies, work_package_id, prerequisite_ids}

    {:error, -32_602, WorkPackageDispatch.error_message(reason),
     %{
       "tool" => "dispatch_work_package",
       "reason" => "unmet_work_package_dependencies",
       "work_package_id" => work_package_id,
       "prerequisite_work_package_ids" => prerequisite_ids,
       "remediation" => "Complete or skip the prerequisite WorkPackages, then retry dispatch_work_package for WorkPackage #{work_package_id}."
     }}
  end

  defp dispatch_work_package_error({:unsupported_branch_pattern, branch_pattern, reason}) do
    invalid_params_error("dispatch_work_package", {:branch_pattern, branch_pattern, reason})
  end

  defp dispatch_work_package_error(reason), do: architect_error(reason, "dispatch_work_package")

  defp append_worktree_lifecycle_audit(repo, %Session{} = session, work_package_id, source_tool, result) do
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

  defp maybe_append_cleanup_worktree_audit(_repo, _session, _work_package_id, %{status: "already_clean"}), do: {:ok, nil}

  defp maybe_append_cleanup_worktree_audit(repo, %Session{} = session, work_package_id, result) do
    append_worktree_lifecycle_audit(repo, session, work_package_id, "cleanup_work_package_worktree", result)
  end

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

  defp optional_work_request_status(arguments) do
    case Map.fetch(arguments, "status") do
      :error ->
        {:ok, nil}

      {:ok, status} when is_binary(status) ->
        status = String.trim(status)

        if status in WorkRequest.statuses() do
          {:ok, status}
        else
          {:tool_error, "invalid_status"}
        end

      {:ok, _status} ->
        {:tool_error, "invalid_status"}
    end
  end

  defp list_pagination(arguments) do
    with {:ok, limit} <- optional_positive_integer_argument(arguments, "limit"),
         limit = limit || @default_list_limit,
         :ok <- require_list_limit(limit),
         {:ok, cursor} <- optional_string_argument(arguments, "cursor"),
         {:ok, cursor} <- decode_list_cursor(cursor) do
      {:ok, %{limit: limit, cursor: cursor}}
    end
  end

  defp require_list_limit(limit) when limit <= @max_list_limit, do: :ok
  defp require_list_limit(_limit), do: {:tool_error, "limit_exceeds_maximum"}

  defp decode_list_cursor(nil), do: {:ok, nil}

  defp decode_list_cursor(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, %{"inserted_at" => inserted_at, "id" => id}} <- Jason.decode(json),
         {:ok, inserted_at, _offset} <- DateTime.from_iso8601(inserted_at),
         true <- is_binary(id) and String.trim(id) != "" do
      {:ok, {inserted_at, id}}
    else
      _invalid -> {:tool_error, "invalid_cursor"}
    end
  end

  defp local_work_request_page(repo, repository_filters, %{limit: limit, cursor: cursor}) do
    with {:ok, candidates} <- WorkRequestService.list_page(repo, repository_filters, limit + 1, cursor) do
      {work_requests, additional} = Enum.split(candidates, limit)
      next_cursor = if additional == [], do: nil, else: encode_list_cursor(List.last(work_requests))
      {:ok, work_requests, next_cursor}
    end
  end

  defp scoped_work_request_page(repo, repository_filters, filters, session, opts, %{limit: limit, cursor: cursor}) do
    page = %{limit: limit, cursor: cursor, collected: [], batches_left: @max_list_candidate_batches}

    collect_scoped_work_request_page(
      repo,
      repository_filters,
      filters,
      session,
      opts,
      page
    )
  end

  defp collect_scoped_work_request_page(repo, repository_filters, filters, session, opts, page) do
    with {:ok, candidates} <-
           WorkRequestService.list_page(repo, repository_filters, @list_candidate_batch_size, page.cursor),
         {:ok, visible} <- WorkRequestScope.filter_scoped_work_requests(repo, candidates, filters, session, opts) do
      collected = page.collected ++ visible

      cond do
        length(collected) > page.limit ->
          {work_requests, _additional} = Enum.split(collected, page.limit)
          {:ok, work_requests, encode_list_cursor(List.last(work_requests))}

        length(candidates) < @list_candidate_batch_size ->
          {:ok, collected, nil}

        page.batches_left == 1 ->
          {:ok, collected, encode_list_cursor(List.last(candidates))}

        true ->
          collect_scoped_work_request_page(
            repo,
            repository_filters,
            filters,
            session,
            opts,
            %{
              page
              | cursor: list_cursor_position(List.last(candidates)),
                collected: collected,
                batches_left: page.batches_left - 1
            }
          )
      end
    end
  end

  defp encode_list_cursor(%WorkRequest{} = work_request) do
    work_request
    |> list_cursor_position()
    |> then(fn {inserted_at, id} ->
      %{"inserted_at" => DateTime.to_iso8601(inserted_at), "id" => id}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)
    end)
  end

  defp list_cursor_position(%WorkRequest{inserted_at: %DateTime{} = inserted_at, id: id}) when is_binary(id),
    do: {inserted_at, id}

  defp work_request_list_payload(cards, scope, status, limit, next_cursor) do
    %{
      "work_requests" => cards,
      "total_count" => length(cards),
      "scope" => scope,
      "filters" => WorkRequestPayloads.work_request_filter(status),
      "limit" => limit
    }
    |> maybe_put_next_cursor(next_cursor)
  end

  defp maybe_put_next_cursor(payload, nil), do: payload
  defp maybe_put_next_cursor(payload, next_cursor), do: Map.put(payload, "next_cursor", next_cursor)

  defp optional_product_tree_view(arguments) do
    case Map.fetch(arguments, "view") do
      :error ->
        {:ok, "groups_with_work_package_refs"}

      {:ok, view} when is_binary(view) ->
        view = String.trim(view)

        if view in @work_request_product_tree_views do
          {:ok, view}
        else
          {:tool_error, "invalid_view"}
        end

      {:ok, _view} ->
        {:tool_error, "invalid_view"}
    end
  end

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp session_claimed_by(%Session{assignment: %{claimed_by: claimed_by}}) when is_binary(claimed_by) do
    case String.trim(claimed_by) do
      "" -> "architect"
      trimmed -> trimmed
    end
  end

  defp session_claimed_by(%Session{}), do: "architect"

  defp require_worktree_work_package_scope(_repo, %WorkPackage{work_request_id: nil}, _filters), do: {:error, :forbidden}

  defp require_worktree_work_package_scope(repo, %WorkPackage{} = work_package, filters) do
    case repo.get(WorkRequest, work_package.work_request_id) do
      %WorkRequest{} = work_request ->
        with :ok <- WorkRequestScope.require_work_package_repo_scope(work_package, work_request, work_package),
             :ok <- WorkRequestScope.require_work_package_delivery_base_scope(work_package, work_package),
             :ok <- WorkRequestScope.require_work_request_scope(repo, work_request, filters) do
          WorkRequestScope.require_delivery_work_package_filter_scope(repo, work_package, work_request, filters)
        end

      nil ->
        {:error, :forbidden}
    end
  end

  defp architect_session(repo, session, capability) when is_binary(capability) do
    with {:ok, session} <- Auth.require_session(session, repo),
         :ok <- require_architect_assignment(session.assignment),
         :ok <- require_architect_capabilities(session.assignment, [capability]) do
      {:ok, session}
    end
  end

  defp require_architect_assignment(%{grant_role: "architect"}), do: :ok
  defp require_architect_assignment(_assignment), do: {:error, :architect_grant_required}

  defp require_architect_capabilities(assignment, capabilities) do
    Enum.reduce_while(capabilities, :ok, fn capability, :ok ->
      case require_architect_capability(assignment, capability) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp require_architect_capability(%{capabilities: capabilities}, capability) when is_list(capabilities) do
    if capability in capabilities do
      :ok
    else
      {:error, :insufficient_capability}
    end
  end

  defp require_architect_capability(_assignment, _capability), do: {:error, :insufficient_capability}

  defp default_claimed_by(%Config{claimed_by: claimed_by}) do
    case normalize_optional_value(claimed_by) do
      claimed_by when is_binary(claimed_by) -> claimed_by
      nil -> "local-agent"
    end
  end

  defp normalize_optional_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_value(nil), do: nil
  defp normalize_optional_value(value), do: value

  defp expected_question_status_argument(arguments) do
    cond do
      Map.has_key?(arguments, "expected_question_status") ->
        parse_question_status_guard(Map.get(arguments, "expected_question_status"))

      Map.has_key?(arguments, "current_status") ->
        parse_question_status_guard(Map.get(arguments, "current_status"))

      true ->
        {:ok, "open"}
    end
  end

  defp parse_question_status_guard(status) when is_binary(status) do
    status
    |> String.trim()
    |> require_open_question_status()
  end

  defp parse_question_status_guard(_status), do: {:tool_error, {:invalid_question_status, "non_string", ["open"]}}

  defp require_open_question_status("open"), do: {:ok, "open"}
  defp require_open_question_status(status), do: {:tool_error, {:invalid_question_status, status, ["open"]}}

  defp answer_question_and_record_decision_transaction(repo, work_request_id, question_id, expected_question_status, attrs) do
    repo.transaction(fn ->
      with {:ok, question_record} <-
             WorkRequestService.answer_question(repo, question_id, expected_question_status, %{
               "answer" => Map.fetch!(attrs, "answer"),
               "answered_by" => Map.fetch!(attrs, "answered_by")
             }),
           {:ok, decision_record} <-
             WorkRequestService.record_decision(
               repo,
               work_request_id,
               optional_put(
                 %{
                   "source_type" => Map.fetch!(attrs, "source_type"),
                   "decision" => Map.fetch!(attrs, "decision"),
                   "rationale" => Map.fetch!(attrs, "rationale"),
                   "scope_impact" => Map.fetch!(attrs, "scope_impact"),
                   "created_by" => Map.fetch!(attrs, "created_by")
                 },
                 "source_id",
                 Map.get(attrs, "source_id")
               )
             ) do
        %{question: question_record, decision: decision_record}
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
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

  defp architect_error({:work_package_scope_violation, errors}, tool) do
    invalid_params_error(tool, {:work_package_scope_violation, errors})
  end

  defp architect_error(reason, tool) when reason in [:invalid_repo_root, :missing_repo_root] do
    invalid_params_error(tool, reason)
  end

  defp architect_error(reason, tool) when reason in [:invalid_target_repo_root, :missing_target_repo_root] do
    invalid_params_error(tool, reason)
  end

  defp architect_error({:git_failed, status, details}, tool) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "git_failed",
       "git" => details |> Map.put(:status, status) |> json_safe_payload() |> Redactor.redact_output()
     }}
  end

  defp architect_error({:stale_existing_branch, details}, tool) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "stale_existing_branch",
       "branch" => details.branch,
       "existing_revision" => details.existing_revision,
       "base_revision" => details.base_revision,
       "base_ref" => details.base_ref,
       "remediation" => details.remediation
     }}
  end

  defp architect_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp invalid_params_error(tool, {:work_package_scope_violation, errors}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "work_package_scope_violation",
       "validation_errors" => scope_validation_details(errors)
     }}
  end

  defp invalid_params_error(tool, {:branch_pattern, value, reason}) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => Atom.to_string(reason),
       "validation_errors" => [
         %{
           "field" => "branch_pattern",
           "value" => value,
           "reason" => Atom.to_string(reason),
           "message" => BranchPattern.error_message(reason)
         }
       ]
     }}
  end

  defp invalid_params_error(tool, {:invalid_question_status, got, expected}) do
    expected = Enum.map(expected, &to_string/1)

    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "invalid_question_status",
       "status_domain" => "clarification_question",
       "expected_statuses" => expected,
       "got" => got,
       "message" => "expected clarification question status=#{Enum.join(expected, " or ")}, got #{got}"
     }}
  end

  defp invalid_params_error(tool, reason) when reason in [:missing_target_repo_root, "missing_target_repo_root"] do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "missing_target_repo_root",
       "message" => "target_repo_root must point to the target product repository root used for git worktree operations."
     }}
  end

  defp invalid_params_error(tool, reason) when reason in [:invalid_target_repo_root, "invalid_target_repo_root"] do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "invalid_target_repo_root",
       "message" => "target_repo_root must point to an existing target product repository root."
     }}
  end

  defp invalid_params_error(tool, reason) do
    {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}
  end

  defp scope_validation_details(errors) when is_list(errors), do: Enum.map(errors, &scope_validation_detail/1)
  defp scope_validation_details(error), do: scope_validation_details([error])

  defp scope_validation_detail({:invalid_constraints, field}) do
    %{"field" => Atom.to_string(field), "reason" => "invalid_constraints"}
  end

  defp scope_validation_detail({:invalid_allowed_file_globs, field}) do
    %{"field" => Atom.to_string(field), "reason" => "invalid_allowed_file_globs"}
  end

  defp scope_validation_detail({:invalid_path, field, value, reason}) do
    %{
      "field" => Atom.to_string(field),
      "value" => value,
      "reason" => Atom.to_string(reason)
    }
  end

  defp scope_validation_detail({:non_documentation_owned_glob, value}) do
    %{
      "field" => "allowed_file_globs",
      "value" => value,
      "reason" => "non_documentation_owned_glob"
    }
  end

  defp scope_validation_detail({:outside_allowed_paths, value, allowed_paths}) do
    %{
      "field" => "allowed_file_globs",
      "value" => value,
      "reason" => "outside_allowed_paths",
      "allowed_paths" => allowed_paths
    }
  end

  defp scope_validation_detail({:forbidden_path_overlap, value, forbidden_path}) do
    %{
      "field" => "allowed_file_globs",
      "value" => value,
      "reason" => "forbidden_path_overlap",
      "forbidden_path" => forbidden_path
    }
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

  defp not_found_error(tool) do
    {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
