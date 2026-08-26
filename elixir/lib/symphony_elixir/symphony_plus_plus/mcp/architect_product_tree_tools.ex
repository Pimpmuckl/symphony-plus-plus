defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ArchitectProductTreeTools do
  @moduledoc false

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_list_argument: 2,
      optional_nonnegative_integer_argument: 2,
      optional_positive_integer_argument: 2,
      optional_object_argument: 2,
      optional_string_argument: 2,
      optional_string_argument: 3,
      required_argument: 2,
      required_object: 2
    ]

  import SymphonyElixir.SymphonyPlusPlus.MCP.Payloads, only: [json_safe_payload: 1]

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Auth,
    Config,
    CurrentWorkRequest,
    ErrorDetails,
    Session,
    ToolResult,
    WorkRequestPayloads,
    WorkRequestScope
  }

  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @work_request_authoring_states ["ready_for_slicing", "sliced"]
  @work_package_terminal_states ["skipped", "merged", "closed", "abandoned"]
  @work_package_authoring_states WorkPackage.statuses() -- @work_package_terminal_states

  @tools [
    "ask_question",
    "record_decision",
    "slice_work_request",
    "update_work_package",
    "upsert_group",
    "delete_group",
    "upsert_dependency",
    "delete_dependency",
    "skip_work_package"
  ]
  @required_work_package_string_fields ["title", "goal"]
  @required_work_package_array_fields [
    "acceptance_criteria",
    "validation_steps",
    "stop_conditions"
  ]

  @spec tools() :: [String.t()]
  def tools, do: @tools

  @spec call(String.t(), Config.t(), Session.t() | nil, map()) :: {:ok, map()} | {:error, integer(), String.t(), map()}
  def call("ask_question", %Config{} = config, session, arguments) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, category} <- required_argument(arguments, "category"),
         {:ok, question} <- required_argument(arguments, "question"),
         {:ok, why_needed} <- required_argument(arguments, "why_needed"),
         {:ok, decision_prompt} <- optional_decision_prompt_argument(arguments, "decision_prompt"),
         {:ok, asked_by_agent_run_id} <- optional_string_argument(arguments, "asked_by_agent_run_id"),
         {:ok, _work_request, filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(
             config.repo,
             session,
             work_request_id,
             :question_create,
             "ask_question"
           ),
         {:ok, question_record} <-
           WorkRequestService.ask_question(
             config.repo,
             work_request_id,
             optional_put(
               %{
                 "category" => category,
                 "question" => question,
                 "why_needed" => why_needed
               },
               "decision_prompt",
               decision_prompt
             )
             |> optional_put("asked_by_agent_run_id", asked_by_agent_run_id)
           ),
         {:ok, updated_work_request} <- WorkRequestScope.scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "clarification_question" => WorkRequestPayloads.clarification_question(question_record),
         "scope" => scope,
         "status" => %{
           "work_request_status" => updated_work_request.status,
           "question_status" => question_record.status
         }
       })}
    else
      {:tool_error, reason} -> invalid_params_error("ask_question", reason)
      {:error, :not_found} -> not_found_error("ask_question")
      {:error, reason} -> architect_error(reason, "ask_question")
    end
  end

  def call("record_decision", %Config{} = config, session, arguments) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- required_argument(arguments, "work_request_id"),
         {:ok, source_type} <- required_argument(arguments, "source_type"),
         {:ok, decision} <- required_argument(arguments, "decision"),
         {:ok, rationale} <- required_argument(arguments, "rationale"),
         {:ok, scope_impact} <- required_argument(arguments, "scope_impact"),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", session_claimed_by(session)),
         {:ok, source_id} <- optional_string_argument(arguments, "source_id"),
         {:ok, _work_request, filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :decision_record, "record_decision"),
         {:ok, decision_record} <-
           WorkRequestService.record_decision(
             config.repo,
             work_request_id,
             optional_put(
               %{
                 "source_type" => source_type,
                 "decision" => decision,
                 "rationale" => rationale,
                 "scope_impact" => scope_impact,
                 "created_by" => created_by
               },
               "source_id",
               source_id
             )
           ),
         {:ok, updated_work_request} <- WorkRequestScope.scoped_work_request(config.repo, work_request_id, filters) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(updated_work_request),
         "decision_log_entry" => WorkRequestPayloads.decision_log_entry(decision_record),
         "scope" => scope,
         "status" => %{"work_request_status" => updated_work_request.status}
       })}
    else
      {:tool_error, reason} -> invalid_params_error("record_decision", reason)
      {:error, :not_found} -> not_found_error("record_decision")
      {:error, reason} -> architect_error(reason, "record_decision")
    end
  end

  def call("slice_work_request", %Config{} = config, session, arguments) do
    tool = "slice_work_request"

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, work_packages} <- optional_list_argument(arguments, "work_packages"),
         :ok <- require_work_package_batch(work_packages),
         {:ok, work_request, _filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :work_package_create, tool),
         :ok <- require_work_package_authoring_status(work_request),
         :ok <- require_complete_work_package_contracts(work_packages),
         {:ok, {result, detail}} <-
           mutate_product_tree_with_projection(
             config.repo,
             work_request_id,
             tool,
             session_claimed_by(session),
             fn ->
               WorkRequestService.slice_work_request(
                 config.repo,
                 work_request_id,
                 Enum.map(work_packages, &internal_work_package_contract/1)
               )
             end
           ) do
      {:ok,
       ToolResult.tool_result(%{
         "work_package_ids" => Enum.map(result.work_packages, & &1.id),
         "product_tree_revision" => json_safe_payload(detail.product_tree.latest_revision),
         "scope" => scope,
         "status" => %{"work_request_status" => result.work_request.status}
       })}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, %Ecto.Changeset{} = changeset} -> changeset_invalid_params_error(tool, "invalid_work_package", changeset)
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  def call("update_work_package", %Config{} = config, session, arguments) do
    tool = "update_work_package"

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, expected_revision} <- optional_positive_integer_argument(arguments, "expected_contract_revision"),
         {:ok, patch} <- required_object(arguments, "patch"),
         :ok <- require_positive_revision(expected_revision),
         {:ok, work_request, work_package, _filters, scope} <-
           WorkRequestScope.authorized_work_package_scope(
             config.repo,
             session,
             work_request_id,
             work_package_id,
             :work_package_update,
             tool
           ),
         :ok <- require_contract_revision(work_package, expected_revision),
         :ok <- require_work_package_authoring_status(work_request, work_package.contract_revision),
         :ok <- require_mutable_work_package_contract(work_package),
         :ok <- require_complete_work_package_contracts([effective_work_package_contract(work_package, patch)]),
         {:ok, work_package} <-
           mutate_product_tree(config.repo, work_request_id, tool, session_claimed_by(session), fn ->
             update_work_package(
               config.repo,
               work_request_id,
               work_package_id,
               expected_revision,
               internal_work_package_contract(patch)
             )
           end) do
      {:ok,
       ToolResult.tool_result(%{
         "work_package_id" => work_package.id,
         "contract_revision" => work_package.contract_revision,
         "scope" => scope,
         "status" => %{"work_package_status" => work_package.status}
       })}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, %Ecto.Changeset{} = changeset} -> changeset_invalid_params_error(tool, "invalid_work_package", changeset)
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  def call("upsert_group", %Config{} = config, session, arguments) do
    tool = "upsert_group"
    parent_group_id_supplied? = Map.has_key?(arguments, "parent_group_id")
    description_supplied? = Map.has_key?(arguments, "description")

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, group_id} <- optional_string_argument(arguments, "group_id"),
         {:ok, title} <- optional_string_argument(arguments, "title"),
         {:ok, description} <- optional_string_argument(arguments, "description"),
         {:ok, kind} <- optional_string_argument(arguments, "kind"),
         {:ok, parent_group_id} <- optional_string_argument(arguments, "parent_group_id"),
         {:ok, position} <- optional_nonnegative_integer_argument(arguments, "position"),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", session_claimed_by(session)),
         :ok <-
           require_group_mutation(
             group_id,
             title,
             description_supplied?,
             kind,
             parent_group_id_supplied?,
             position
           ),
         {:ok, work_request, _filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, tool),
         :ok <- require_work_package_authoring_status(work_request),
         attrs =
           %{"work_request_id" => work_request_id}
           |> optional_put("id", group_id)
           |> optional_put("title", title)
           |> optional_put_present("description", description, description_supplied?)
           |> optional_put("node_kind", kind)
           |> optional_put_present("parent_id", parent_group_id, parent_group_id_supplied?)
           |> optional_put("position", position)
           |> optional_put("created_by", created_by),
         {:ok, {group, detail}} <-
           mutate_product_tree_with_projection(config.repo, work_request_id, tool, created_by, fn ->
             ProductTree.upsert_node(config.repo, attrs)
           end) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
         "group" => WorkRequestPayloads.group(group),
         "product_tree" => WorkRequestPayloads.public_product_tree(detail.product_tree),
         "scope" => scope,
         "status" => %{"work_request_status" => work_request.status}
       })}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, %Ecto.Changeset{} = changeset} -> changeset_invalid_params_error(tool, "invalid_group", changeset)
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  def call("delete_group", %Config{} = config, session, arguments) do
    mutate_graph_record(config, session, arguments, "delete_group", "group_id", fn work_request_id, group_id ->
      ProductTree.delete_group(config.repo, work_request_id, group_id)
    end)
  end

  def call("upsert_dependency", %Config{} = config, session, arguments) do
    tool = "upsert_dependency"

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, dependency_id} <- optional_string_argument(arguments, "dependency_id"),
         {:ok, dependent} <- required_object(arguments, "dependent"),
         {:ok, prerequisite} <- required_object(arguments, "prerequisite"),
         {:ok, {source_kind, source_id}} <- dependency_endpoint(dependent),
         {:ok, {target_kind, target_id}} <- dependency_endpoint(prerequisite),
         {:ok, reason} <- optional_string_argument(arguments, "reason"),
         {:ok, decision_ref} <- optional_object_argument(arguments, "decision_ref"),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", session_claimed_by(session)),
         {:ok, work_request, _filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, tool),
         :ok <- require_work_package_authoring_status(work_request),
         attrs =
           %{
             "work_request_id" => work_request_id,
             "source_kind" => source_kind,
             "source_id" => source_id,
             "target_kind" => target_kind,
             "target_id" => target_id,
             "kind" => "depends_on"
           }
           |> optional_put("id", dependency_id)
           |> optional_put("reason", reason)
           |> optional_put("decision_ref", decision_ref)
           |> optional_put("created_by", created_by),
         {:ok, {dependency, detail}} <-
           mutate_product_tree_with_projection(config.repo, work_request_id, tool, created_by, fn ->
             ProductTree.upsert_dependency_edge(config.repo, attrs)
           end) do
      {:ok,
       ToolResult.tool_result(%{
         "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
         "dependency" => WorkRequestPayloads.dependency_intent(dependency),
         "product_tree" => WorkRequestPayloads.public_product_tree(detail.product_tree),
         "product_tree_revision" => json_safe_payload(detail.product_tree.latest_revision),
         "scope" => scope,
         "status" => %{"work_request_status" => work_request.status}
       })}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, %Ecto.Changeset{} = changeset} -> changeset_invalid_params_error(tool, "invalid_dependency", changeset)
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  def call("delete_dependency", %Config{} = config, session, arguments) do
    mutate_graph_record(config, session, arguments, "delete_dependency", "dependency_id", fn work_request_id, dependency_id ->
      ProductTree.delete_dependency_edge(config.repo, work_request_id, dependency_id)
    end)
  end

  def call("skip_work_package", %Config{} = config, session, arguments) do
    tool = "skip_work_package"

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, work_request, work_package, _filters, scope} <-
           WorkRequestScope.authorized_work_package_scope(
             config.repo,
             session,
             work_request_id,
             work_package_id,
             :work_package_skip,
             tool
           ),
         :ok <- require_work_package_authoring_status(work_request, work_package.contract_revision),
         :ok <- require_mutable_work_package_contract(work_package),
         {:ok, work_package} <-
           mutate_product_tree(config.repo, work_request_id, tool, session_claimed_by(session), fn ->
             WorkRequestService.skip_work_package(config.repo, work_request_id, work_package_id, current_status)
           end) do
      {:ok,
       ToolResult.tool_result(%{
         "work_package_id" => work_package.id,
         "scope" => scope,
         "status" => %{"work_package_status" => work_package.status}
       })}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  defp mutate_graph_record(%Config{} = config, session, arguments, tool, id_key, mutation_fun) do
    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, id} <- required_argument(arguments, id_key),
         {:ok, work_request, _filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, tool),
         :ok <- require_work_package_authoring_status(work_request),
         created_by = session_claimed_by(session),
         {:ok, {deleted, detail}} <-
           mutate_product_tree_with_projection(config.repo, work_request_id, tool, created_by, fn ->
             mutation_fun.(work_request_id, id)
           end) do
      payload =
        %{
          "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
          "deleted" => deleted_graph_record_payload(tool, deleted),
          "product_tree" => WorkRequestPayloads.public_product_tree(detail.product_tree),
          "scope" => scope,
          "status" => %{"work_request_status" => work_request.status}
        }

      payload =
        if tool == "delete_dependency",
          do: Map.put(payload, "product_tree_revision", json_safe_payload(detail.product_tree.latest_revision)),
          else: payload

      {:ok, ToolResult.tool_result(payload)}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  defp deleted_graph_record_payload("delete_group", result) do
    %{
      "group_id" => result.group.id,
      "parent_group_id" => result.parent_group_id,
      "moved_group_count" => result.moved_group_count,
      "moved_work_package_count" => result.moved_work_package_count,
      "removed_dependency_count" => result.removed_dependency_count
    }
  end

  defp deleted_graph_record_payload("delete_dependency", dependency) do
    WorkRequestPayloads.dependency_intent(dependency)
  end

  defp require_contract_revision(%WorkPackage{contract_revision: revision}, revision), do: :ok

  defp require_contract_revision(%WorkPackage{} = work_package, _expected_revision) do
    {:error, {:contract_revision_conflict, work_package.status, work_package.contract_revision}}
  end

  defp require_work_package_authoring_status(%WorkRequest{} = work_request),
    do: require_work_package_authoring_status(work_request, nil)

  defp require_work_package_authoring_status(%WorkRequest{archived_at: %DateTime{}}, revision),
    do: {:error, {:work_request_terminal, "archived", revision}}

  defp require_work_package_authoring_status(
         %WorkRequest{completed_at: %DateTime{}, completion_source: "operator"},
         revision
       ),
       do: {:error, {:work_request_terminal, "completed", revision}}

  defp require_work_package_authoring_status(%WorkRequest{status: status}, revision) when status in ["completed", "archived"],
    do: {:error, {:work_request_terminal, status, revision}}

  defp require_work_package_authoring_status(%WorkRequest{status: status}, _revision)
       when status in @work_request_authoring_states,
       do: :ok

  defp require_work_package_authoring_status(%WorkRequest{status: status}, revision),
    do: {:error, {:work_request_not_authorable, status, revision}}

  defp require_mutable_work_package_contract(%WorkPackage{status: status} = work_package)
       when status in @work_package_terminal_states do
    {:error, {:work_package_terminal, status, work_package.contract_revision}}
  end

  defp require_mutable_work_package_contract(%WorkPackage{}), do: :ok

  defp update_work_package(repo, work_request_id, work_package_id, expected_revision, patch) do
    case WorkRequestService.update_work_package(repo, work_request_id, work_package_id, expected_revision, patch) do
      {:error, reason} when reason in [:stale_status, :invalid_status] ->
        with {:ok, work_package} <- WorkRequestService.get_work_package(repo, work_request_id, work_package_id),
             :ok <- require_contract_revision(work_package, expected_revision),
             :ok <- require_mutable_work_package_contract(work_package) do
          {:error, reason}
        end

      result ->
        result
    end
  end

  defp require_group_mutation(nil, title, _description_supplied?, _kind, _parent_supplied?, _position) do
    if filled_string?(title), do: :ok, else: {:tool_error, "missing_title"}
  end

  defp require_group_mutation(_group_id, title, description_supplied?, kind, parent_supplied?, position) do
    if Enum.any?([title, kind], &filled_string?/1) or description_supplied? or parent_supplied? or is_integer(position),
      do: :ok,
      else: {:tool_error, "missing_group_mutation"}
  end

  defp dependency_endpoint(%{"kind" => kind, "id" => id})
       when kind in ["group", "work_package"] and is_binary(id) and id != "" do
    {:ok, {if(kind == "group", do: "product_node", else: kind), id}}
  end

  defp dependency_endpoint(_endpoint), do: {:tool_error, "invalid_dependency_endpoint"}

  defp mutate_product_tree(repo, work_request_id, tool, created_by, mutation_fun) do
    run_architect_transaction(repo, fn ->
      with {:ok, result} <- mutation_fun.(),
           {:ok, _revision} <- record_current_product_tree_revision(repo, work_request_id, tool, created_by) do
        {:ok, result}
      end
    end)
  end

  defp mutate_product_tree_with_projection(repo, work_request_id, tool, created_by, mutation_fun) do
    run_architect_transaction(repo, fn ->
      with {:ok, result} <- mutation_fun.(),
           {:ok, _revision} <- record_current_product_tree_revision(repo, work_request_id, tool, created_by),
           {:ok, detail} <- Dashboard.work_request_detail(repo, work_request_id) do
        {:ok, {result, detail}}
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
    |> json_safe_payload()
    |> Map.delete("latest_revision")
    |> Map.delete("execution_graph")
  end

  defp product_tree_revision_reason("slice_work_request"), do: "WorkRequest sliced into canonical WorkPackages through MCP."
  defp product_tree_revision_reason("update_work_package"), do: "WorkPackage contract updated through MCP."
  defp product_tree_revision_reason("upsert_group"), do: "Group content or placement changed through MCP."
  defp product_tree_revision_reason("delete_group"), do: "Group removed through MCP."
  defp product_tree_revision_reason("upsert_dependency"), do: "Execution dependency changed through MCP."
  defp product_tree_revision_reason("delete_dependency"), do: "Execution dependency removed through MCP."
  defp product_tree_revision_reason("skip_work_package"), do: "WorkPackage skipped in product tree through MCP."

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

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp optional_put_present(attrs, key, value, true), do: Map.put(attrs, key, value)
  defp optional_put_present(attrs, _key, _value, false), do: attrs

  defp session_claimed_by(%Session{assignment: %{claimed_by: claimed_by}}) when is_binary(claimed_by) do
    case String.trim(claimed_by) do
      "" -> "architect"
      trimmed -> trimmed
    end
  end

  defp session_claimed_by(%Session{}), do: "architect"

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp require_work_package_batch([first | rest]) when is_map(first) do
    if Enum.all?(rest, &is_map/1), do: :ok, else: {:tool_error, "invalid_work_packages"}
  end

  defp require_work_package_batch(_work_packages), do: {:tool_error, "invalid_work_packages"}

  defp require_complete_work_package_contracts(work_packages) do
    if Enum.all?(work_packages, &complete_work_package_contract?/1) do
      :ok
    else
      {:tool_error, "invalid_work_packages"}
    end
  end

  defp complete_work_package_contract?(work_package) do
    Enum.all?(@required_work_package_string_fields, &filled_string?(Map.get(work_package, &1))) and
      Enum.all?(@required_work_package_array_fields, &string_list?(Map.get(work_package, &1)))
  end

  defp effective_work_package_contract(work_package, patch) do
    %{
      "title" => work_package.title,
      "goal" => work_package.goal,
      "allowed_file_globs" => work_package.allowed_file_globs,
      "acceptance_criteria" => work_package.acceptance_criteria,
      "validation_steps" => work_package.validation_steps,
      "stop_conditions" => work_package.stop_conditions
    }
    |> Map.merge(patch)
  end

  defp internal_work_package_contract(contract) do
    if Map.has_key?(contract, "group_id") do
      contract
      |> Map.put("product_tree_node_id", Map.get(contract, "group_id"))
      |> Map.delete("group_id")
    else
      contract
    end
  end

  defp string_list?(values) when is_list(values), do: Enum.all?(values, &filled_string?/1)
  defp string_list?(_values), do: false

  defp require_positive_revision(revision) when is_integer(revision) and revision > 0, do: :ok
  defp require_positive_revision(_revision), do: {:tool_error, "invalid_contract_revision"}

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

  defp architect_error({:work_request_terminal, status}, tool),
    do: architect_error({:work_request_terminal, status, nil}, tool)

  defp architect_error({reason, status, revision}, tool)
       when reason in [:work_request_terminal, :work_request_not_authorable] do
    details =
      %{
        "actual_status" => reason_text(status),
        "allowed_authoring_states" => @work_request_authoring_states
      }
      |> optional_put("current_contract_revision", revision)

    ErrorDetails.lifecycle_error(tool, reason, details)
  end

  defp architect_error({reason, status, revision}, tool)
       when reason in [:contract_revision_conflict, :work_package_terminal] do
    ErrorDetails.lifecycle_error(tool, reason, %{
      "actual_status" => reason_text(status),
      "allowed_authoring_states" => if(tool == "skip_work_package", do: ["planned"], else: @work_package_authoring_states),
      "current_contract_revision" => revision
    })
  end

  defp architect_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp architect_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)

  defp architect_error(:open_questions, tool) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "open_questions",
       "message" => "Answer or close all open clarification questions before adding WorkPackages."
     }}
  end

  defp architect_error(reason, tool), do: {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}

  defp invalid_params_error(tool, reason) do
    {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}
  end

  defp changeset_invalid_params_error(tool, reason, %Ecto.Changeset{} = changeset) do
    ErrorDetails.changeset_invalid_params_error(tool, reason, changeset)
  end

  defp auth_error(:unauthorized, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}

  defp auth_error({:unauthorized, reason}, resource),
    do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}

  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)
  defp auth_error(:forbidden, resource), do: {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}

  defp service_error(_reason, resource), do: {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  defp not_found_error(tool), do: {:error, -32_004, "Not found", %{"tool" => tool, "reason" => "not_found"}}

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
