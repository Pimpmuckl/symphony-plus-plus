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
  alias SymphonyElixir.SymphonyPlusPlus.BranchPattern
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    ArchitectDeliveryTools,
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
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Node
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService

  @tools [
    "ask_question",
    "record_decision",
    "slice_work_request",
    "update_work_package",
    "upsert_plan_node",
    "move_plan_node",
    "set_plan_node_completion",
    "skip_work_package"
  ]
  @required_work_package_string_fields ["title", "goal"]
  @required_work_package_array_fields [
    "allowed_file_globs",
    "acceptance_criteria",
    "validation_steps",
    "stop_conditions"
  ]
  @terminal_product_tree_completion_marks ["done", "deferred"]

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
         {:ok, created_by} <- required_argument(arguments, "created_by"),
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
         {:ok, _work_request, _filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :work_package_create, tool),
         :ok <- require_complete_work_package_contracts(work_packages),
         {:ok, result} <-
           mutate_product_tree(
             config.repo,
             work_request_id,
             tool,
             session_claimed_by(session),
             fn -> WorkRequestService.slice_work_request(config.repo, work_request_id, work_packages) end
           ) do
      {:ok,
       ToolResult.tool_result(%{
         "work_package_ids" => Enum.map(result.work_packages, & &1.id),
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
         {:ok, work_request, _work_package, _filters, scope} <-
           WorkRequestScope.authorized_work_package_scope(
             config.repo,
             session,
             work_request_id,
             work_package_id,
             :work_package_update,
             tool
           ),
         :ok <- require_work_package_authoring_status(work_request.status),
         {:ok, work_package} <-
           mutate_product_tree(config.repo, work_request_id, tool, session_claimed_by(session), fn ->
             WorkRequestService.update_work_package(
               config.repo,
               work_request_id,
               work_package_id,
               expected_revision,
               patch
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

  def call("upsert_plan_node", %Config{} = config, session, arguments) do
    tool = "upsert_plan_node"

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, product_tree_node_id} <- optional_string_argument(arguments, "product_tree_node_id"),
         {:ok, title} <- optional_string_argument(arguments, "title"),
         {:ok, description} <- optional_string_argument(arguments, "description"),
         {:ok, node_kind} <- optional_string_argument(arguments, "node_kind"),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", session_claimed_by(session)),
         :ok <- require_product_plan_node_content(product_tree_node_id, title, description, node_kind),
         {:ok, work_request, _filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, tool),
         :ok <- require_work_package_authoring_status(work_request.status),
         {:ok, current_parent_id} <- product_plan_node_current_parent_id(config.repo, work_request_id, product_tree_node_id),
         attrs =
           %{
             "work_request_id" => work_request_id
           }
           |> optional_put("id", product_tree_node_id)
           |> optional_put("parent_id", current_parent_id)
           |> optional_put("title", title)
           |> optional_put("description", description)
           |> optional_put("node_kind", node_kind)
           |> optional_put("created_by", created_by),
         {:ok, {{product_tree_node, blocker_closeout}, detail}} <-
           mutate_product_plan_node(config.repo, session, work_request_id, tool, created_by, attrs, :not_needed) do
      {:ok, product_plan_node_tool_result(work_request, product_tree_node, blocker_closeout, detail, scope)}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, %Ecto.Changeset{} = changeset} -> changeset_invalid_params_error(tool, "invalid_product_plan_node", changeset)
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  def call("move_plan_node", %Config{} = config, session, arguments) do
    tool = "move_plan_node"
    parent_id_supplied? = Map.has_key?(arguments, "parent_id")

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, product_tree_node_id} <- required_argument(arguments, "product_tree_node_id"),
         {:ok, parent_id} <- optional_string_argument(arguments, "parent_id"),
         {:ok, position} <- optional_nonnegative_integer_argument(arguments, "position"),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", session_claimed_by(session)),
         :ok <- require_product_plan_node_topology(parent_id_supplied?, position),
         {:ok, work_request, _filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, tool),
         :ok <- require_work_package_authoring_status(work_request.status),
         attrs =
           %{
             "work_request_id" => work_request_id,
             "id" => product_tree_node_id
           }
           |> optional_put_present("parent_id", parent_id, parent_id_supplied?)
           |> optional_put("position", position)
           |> optional_put("created_by", created_by),
         {:ok, {{product_tree_node, blocker_closeout}, detail}} <-
           mutate_product_plan_node(config.repo, session, work_request_id, tool, created_by, attrs, :not_needed) do
      {:ok, product_plan_node_tool_result(work_request, product_tree_node, blocker_closeout, detail, scope)}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, %Ecto.Changeset{} = changeset} -> changeset_invalid_params_error(tool, "invalid_product_plan_node", changeset)
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  def call("set_plan_node_completion", %Config{} = config, session, arguments) do
    tool = "set_plan_node_completion"

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, product_tree_node_id} <- required_argument(arguments, "product_tree_node_id"),
         {:ok, completion_mark} <- required_argument(arguments, "completion_mark"),
         :ok <- require_product_tree_completion_mark(completion_mark),
         {:ok, created_by} <- optional_string_argument(arguments, "created_by", session_claimed_by(session)),
         {:ok, work_request, _filters, scope} <-
           WorkRequestScope.authorized_work_request_scope(config.repo, session, work_request_id, :work_request_update, tool),
         :ok <- require_work_package_authoring_status(work_request.status),
         attrs =
           %{
             "work_request_id" => work_request_id,
             "id" => product_tree_node_id,
             "completion_mark" => completion_mark
           }
           |> optional_put("created_by", created_by),
         {:ok, blocker_closeout_plan} <-
           maybe_prepare_product_plan_node_blocker_closeout(
             config.repo,
             session,
             work_request_id,
             product_tree_node_id,
             completion_mark,
             arguments,
             tool
           ),
         {:ok, {{product_tree_node, blocker_closeout}, detail}} <-
           mutate_product_plan_node(config.repo, session, work_request_id, tool, created_by, attrs, blocker_closeout_plan) do
      {:ok, product_plan_node_tool_result(work_request, product_tree_node, blocker_closeout, detail, scope)}
    else
      {:tool_error, reason} -> invalid_params_error(tool, reason)
      {:error, %Ecto.Changeset{} = changeset} -> changeset_invalid_params_error(tool, "invalid_product_plan_node", changeset)
      {:error, :not_found} -> not_found_error(tool)
      {:error, reason} -> architect_error(reason, tool)
    end
  end

  def call("skip_work_package", %Config{} = config, session, arguments) do
    tool = "skip_work_package"

    with {:ok, session} <- Auth.require_session(session, config.repo),
         {:ok, work_request_id} <- CurrentWorkRequest.id_argument(arguments, session),
         {:ok, work_package_id} <- required_argument(arguments, "work_package_id"),
         {:ok, current_status} <- required_argument(arguments, "current_status"),
         {:ok, work_request, _work_package, _filters, scope} <-
           WorkRequestScope.authorized_work_package_scope(
             config.repo,
             session,
             work_request_id,
             work_package_id,
             :work_package_skip,
             tool
           ),
         :ok <- require_work_package_authoring_status(work_request.status),
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

  defp upsert_product_plan_node_with_blocker_closeout(repo, %Session{} = session, attrs, blocker_closeout_plan) do
    with {:ok, product_tree_node} <- ProductTree.upsert_node(repo, attrs),
         {:ok, blocker_closeout} <-
           ArchitectDeliveryTools.apply_prepared_blocker_closeout(repo, session, blocker_closeout_plan) do
      {:ok, {product_tree_node, blocker_closeout}}
    end
  end

  defp mutate_product_plan_node(repo, %Session{} = session, work_request_id, tool, created_by, attrs, blocker_closeout_plan) do
    mutate_product_tree_with_projection(repo, work_request_id, tool, created_by, fn ->
      upsert_product_plan_node_with_blocker_closeout(repo, session, attrs, blocker_closeout_plan)
    end)
  end

  defp product_plan_node_tool_result(work_request, product_tree_node, blocker_closeout, detail, scope) do
    ToolResult.tool_result(%{
      "work_request" => WorkRequestPayloads.work_request_mutation(work_request),
      "product_plan_node" => WorkRequestPayloads.product_tree_node(product_tree_node),
      "blocker_closeout" => blocker_closeout,
      "product_tree" => json_safe_payload(detail.product_tree),
      "scope" => scope,
      "status" => %{"work_request_status" => work_request.status}
    })
  end

  defp product_plan_node_current_parent_id(_repo, _work_request_id, nil), do: {:ok, nil}

  defp product_plan_node_current_parent_id(repo, work_request_id, product_tree_node_id) do
    with {:ok, tree} <- ProductTree.tree_for_work_request(repo, work_request_id) do
      case Enum.find(tree.nodes, &(&1.id == product_tree_node_id)) do
        %Node{} = node -> {:ok, node.parent_id}
        nil -> {:error, :not_found}
      end
    end
  end

  defp maybe_prepare_product_plan_node_blocker_closeout(_repo, %Session{}, _work_request_id, _node_id, completion_mark, _arguments, _tool)
       when completion_mark not in @terminal_product_tree_completion_marks do
    {:ok, :not_needed}
  end

  defp maybe_prepare_product_plan_node_blocker_closeout(repo, %Session{} = session, work_request_id, product_tree_node_id, _completion_mark, arguments, tool) do
    with {:ok, work_package_ids} <- product_plan_node_work_package_ids(repo, work_request_id, product_tree_node_id) do
      ArchitectDeliveryTools.prepare_scoped_blocker_closeout(repo, session, work_package_ids, arguments, tool)
    end
  end

  defp product_plan_node_work_package_ids(repo, work_request_id, product_tree_node_id) do
    with {:ok, tree} <- ProductTree.tree_for_work_request(repo, work_request_id),
         {:ok, work_packages} <- WorkRequestService.list_work_packages(repo, work_request_id) do
      subtree_node_ids = product_tree_subtree_node_ids(tree.nodes, product_tree_node_id)

      package_ids =
        work_packages
        |> Enum.filter(&(&1.product_tree_node_id in subtree_node_ids))
        |> Enum.map(& &1.id)

      {:ok, package_ids}
    end
  end

  defp product_tree_subtree_node_ids(nodes, product_tree_node_id) do
    children_by_parent = Enum.group_by(nodes, & &1.parent_id)

    Stream.unfold([product_tree_node_id], fn
      [] ->
        nil

      [node_id | rest] ->
        child_ids = children_by_parent |> Map.get(node_id, []) |> Enum.map(& &1.id)
        {node_id, rest ++ child_ids}
    end)
    |> Enum.to_list()
  end

  defp require_work_package_authoring_status(status) when status in ["ready_for_slicing", "sliced"], do: :ok
  defp require_work_package_authoring_status(_status), do: {:tool_error, "invalid_status"}

  defp require_product_plan_node_content(nil, title, _description, _node_kind) do
    if filled_string?(title), do: :ok, else: {:tool_error, "missing_title"}
  end

  defp require_product_plan_node_content(_product_tree_node_id, title, description, node_kind) do
    if Enum.any?([title, description, node_kind], &filled_string?/1),
      do: :ok,
      else: {:tool_error, "missing_product_plan_node_content"}
  end

  defp require_product_plan_node_topology(parent_id_supplied?, position) do
    if parent_id_supplied? or is_integer(position),
      do: :ok,
      else: {:tool_error, "missing_product_plan_node_topology"}
  end

  defp require_product_tree_completion_mark(completion_mark) do
    if completion_mark in Node.completion_marks(),
      do: :ok,
      else: {:tool_error, "invalid_completion_mark"}
  end

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
  end

  defp product_tree_revision_reason("slice_work_request"), do: "WorkRequest sliced into canonical WorkPackages through MCP."
  defp product_tree_revision_reason("update_work_package"), do: "WorkPackage contract updated through MCP."
  defp product_tree_revision_reason("upsert_plan_node"), do: "Product plan node content changed through MCP."
  defp product_tree_revision_reason("move_plan_node"), do: "Product plan node rearranged through MCP."
  defp product_tree_revision_reason("set_plan_node_completion"), do: "Product plan node completion changed through MCP."
  defp product_tree_revision_reason("skip_work_package"), do: "WorkPackage skipped in product tree through MCP."

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

  defp string_list?(values) when is_list(values), do: Enum.all?(values, &is_binary/1)
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
  defp architect_error({:work_request_terminal, _terminal_state}, resource), do: auth_error(:forbidden, resource)
  defp architect_error(:forbidden, resource), do: auth_error(:forbidden, resource)
  defp architect_error({:service_unavailable, _reason} = reason, resource), do: auth_error(reason, resource)
  defp architect_error(:database_busy, tool), do: service_error(:database_busy, tool)
  defp architect_error({:storage_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error({:migration_failed, _reason} = reason, tool), do: service_error(reason, tool)
  defp architect_error({:work_package_scope_violation, errors}, tool), do: invalid_params_error(tool, {:work_package_scope_violation, errors})

  defp architect_error(:open_questions, tool) do
    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "open_questions",
       "message" => "Answer or close all open clarification questions before adding WorkPackages."
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
    ErrorDetails.changeset_invalid_params_error(tool, reason, changeset)
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
