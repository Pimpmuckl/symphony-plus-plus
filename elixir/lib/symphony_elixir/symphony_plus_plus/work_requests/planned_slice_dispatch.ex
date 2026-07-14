defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDispatch do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.BranchPattern
  alias SymphonyElixir.SymphonyPlusPlus.CreateWork
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDeliveryScope
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ScopeConstraints
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @mcp_worker_skill "symphony-plus-plus-mcp:symphony-worker"
  @default_worker_skill "symphony-plus-plus:symphony-worker"
  @mcp_work_package_skill "symphony-plus-plus-mcp:symphony-work-package"
  @repo_work_package_skill "symphony-work-package"
  @preferred_worker_skill_set [@mcp_worker_skill, @mcp_work_package_skill]

  @type dispatch_result :: %{
          work_request: WorkRequest.t(),
          planned_slice: PlannedSlice.t(),
          creation: CreateWork.creation(),
          worker_bootstrap: map()
        }

  @type error ::
          Repository.error()
          | CreateWork.error()
          | {:invalid_planned_slice_status, String.t() | nil}
          | {:invalid_work_request_status, String.t() | nil}
          | {:planned_slice_scope_violation, [ScopeConstraints.error()]}
          | {:unsupported_branch_pattern, String.t(), atom()}
          | {:kind_not_dispatchable, String.t() | nil}
          | {:dispatch_link_failed, term(), map()}

  @spec dispatch(module(), String.t(), String.t(), keyword()) :: {:ok, dispatch_result()} | {:error, error()}
  @spec dispatch(module(), String.t(), String.t(), keyword(), keyword()) ::
          {:ok, dispatch_result()} | {:error, error()}
  def dispatch(repo, work_request_id, planned_slice_id, handoff_opts, opts \\ [])
      when is_atom(repo) and is_binary(work_request_id) and is_binary(planned_slice_id) and is_list(handoff_opts) and
             is_list(opts) do
    with {:ok, work_request, planned_slice} <- load_dispatchable_slice(repo, work_request_id, planned_slice_id),
         :ok <- validate_branch_pattern(planned_slice),
         :ok <- PlannedSliceDeliveryScope.validate(repo, work_request, planned_slice),
         :ok <- validate_slice_scope(work_request, planned_slice),
         request = create_work_request(work_request, planned_slice),
         :ok <- validate_create_work_request(request, planned_slice),
         {:ok, creation} <- create_work(repo, request, opts) do
      link_or_cleanup(repo, work_request, planned_slice, creation, handoff_opts, opts)
    end
  end

  @spec response_payload(dispatch_result()) :: map()
  def response_payload(%{planned_slice: %PlannedSlice{} = planned_slice, creation: creation} = dispatch) do
    bootstrap = Map.get(dispatch, :worker_bootstrap)

    %{
      create_work: CreateWork.response_payload(creation, worker_bootstrap: bootstrap),
      planned_slice_linkage: planned_slice_linkage_payload(planned_slice)
    }
  end

  @spec error_message(term()) :: String.t()
  def error_message(:not_found), do: "WorkRequest planned slice was not found"
  def error_message(:work_package_not_found), do: "Created WorkPackage for planned-slice dispatch was not found"
  def error_message(:invalid_work_package_id), do: "Created WorkPackage id for planned-slice dispatch is invalid"
  def error_message(:work_package_already_linked), do: "Created WorkPackage is already linked to another planned slice"
  def error_message(:work_package_mismatch), do: "Created WorkPackage does not match the planned-slice dispatch contract"

  def error_message({:invalid_planned_slice_status, status}) do
    "Planned slice must be approved before dispatch; current status is #{inspect(status)}"
  end

  def error_message({:invalid_work_request_status, status}) do
    "Parent WorkRequest must be ready_for_slicing or sliced before dispatch; current status is #{inspect(status)}"
  end

  def error_message({:planned_slice_scope_violation, errors}) do
    "Planned slice owned file globs violate WorkRequest path constraints: #{inspect(errors)}"
  end

  def error_message({:unsupported_branch_pattern, branch_pattern, reason}) do
    "Planned slice branch_pattern #{inspect(branch_pattern)} is unsupported: #{BranchPattern.error_message(reason)}"
  end

  def error_message({:kind_not_dispatchable, kind}) do
    "Planned slice kind #{inspect(kind)} is not dispatchable"
  end

  def error_message({:dispatch_link_failed, reason, recovery}) do
    "Created WorkPackage but failed to link planned slice: #{format_reason(reason)}; recovery: #{inspect(recovery)}"
  end

  def error_message(reason), do: CreateWork.error_message(reason)

  defp load_dispatchable_slice(repo, work_request_id, planned_slice_id) do
    with {:ok, %WorkRequest{} = work_request} <- Repository.get(repo, work_request_id),
         {:ok, %PlannedSlice{} = planned_slice} <-
           Repository.get_planned_slice(repo, work_request_id, planned_slice_id),
         :ok <- require_dispatchable_work_request(work_request),
         :ok <- require_approved_planned_slice(planned_slice) do
      {:ok, work_request, planned_slice}
    end
  end

  defp require_dispatchable_work_request(%WorkRequest{status: status})
       when status in ["ready_for_slicing", "sliced"],
       do: :ok

  defp require_dispatchable_work_request(%WorkRequest{status: status}),
    do: {:error, {:invalid_work_request_status, status}}

  defp require_approved_planned_slice(%PlannedSlice{status: "approved"}), do: :ok

  defp require_approved_planned_slice(%PlannedSlice{status: status}),
    do: {:error, {:invalid_planned_slice_status, status}}

  defp validate_branch_pattern(%PlannedSlice{branch_pattern: branch_pattern}) do
    case BranchPattern.validate(branch_pattern) do
      :ok -> :ok
      {:error, reason} -> {:error, {:unsupported_branch_pattern, branch_pattern, reason}}
    end
  end

  defp validate_slice_scope(%WorkRequest{} = work_request, %PlannedSlice{} = planned_slice) do
    with :ok <- ScopeConstraints.validate_owned_file_globs(work_request, planned_slice),
         :ok <- validate_docs_slice_scope(planned_slice) do
      :ok
    else
      {:error, errors} -> {:error, {:planned_slice_scope_violation, errors}}
    end
  end

  defp validate_docs_slice_scope(%PlannedSlice{work_package_kind: "docs", owned_file_globs: owned_file_globs}) do
    ScopeConstraints.validate_docs_owned_file_globs(owned_file_globs || [])
  end

  defp validate_docs_slice_scope(%PlannedSlice{}), do: :ok

  defp create_work_request(%WorkRequest{} = work_request, %PlannedSlice{} = planned_slice) do
    %{
      "repo" => PlannedSlice.delivery_repo(work_request, planned_slice),
      "base_branch" => planned_slice.target_base_branch,
      "title" => planned_slice.title,
      "kind" => planned_slice.work_package_kind,
      "branch_pattern" => nonblank_or_nil(planned_slice.branch_pattern),
      "product_description" => work_request.human_description,
      "engineering_scope" => engineering_scope(work_request, planned_slice),
      "allowed_file_globs" => planned_slice.owned_file_globs || [],
      "acceptance_criteria" => planned_slice.acceptance_criteria || [],
      "review_requirement" => planned_slice.review_requirement
    }
    |> drop_nil_values()
  end

  defp validate_create_work_request(request, %PlannedSlice{} = planned_slice) do
    case CreateWork.parse_request(request) do
      {:ok, _request} ->
        :ok

      {:error, :kind_not_dispatchable} ->
        {:error, {:kind_not_dispatchable, planned_slice.work_package_kind}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_work(repo, request, opts) do
    create_fun = Keyword.get(opts, :create_work, &CreateWork.create/2)
    create_fun.(repo, request)
  end

  defp worker_bootstrap(%WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, creation, handoff_opts) do
    work_package = creation.work_package
    claimed_by = Keyword.get(handoff_opts, :claimed_by)

    claim_arguments =
      %{
        "work_package_id" => work_package.id,
        "claimed_by" => claimed_by
      }
      |> drop_nil_values()

    ledger_database = Keyword.get(handoff_opts, :database)

    %{
      type: "ledger_claim",
      mode: "local_assignment",
      ledger: ledger_bootstrap(ledger_database),
      claim: %{
        tool: "claim_local_assignment",
        arguments: claim_arguments,
        required_runtime_arguments: []
      },
      coordinates: worker_bootstrap_coordinates(work_request, planned_slice, work_package),
      required_skills: @preferred_worker_skill_set,
      preferred_skill_set: @preferred_worker_skill_set,
      supported_skill_sets: supported_worker_skill_sets(),
      launch_prompt:
        worker_launch_prompt(
          work_request,
          planned_slice,
          work_package,
          claim_arguments,
          ledger_database
        )
    }
    |> drop_nil_values()
  end

  defp worker_bootstrap_coordinates(%WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, work_package) do
    %{
      primary_execution: %{kind: "work_package", work_package_id: work_package.id},
      product_audit: %{
        kind: "planned_slice",
        work_request_id: work_request.id,
        planned_slice_id: planned_slice.id
      }
    }
  end

  defp link_or_cleanup(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, creation, handoff_opts, opts) do
    work_package_id = creation.work_package.id

    case link_planned_slice(repo, work_request.id, planned_slice.id, work_package_id, opts) do
      {:ok, linked_slice} ->
        worker_bootstrap = worker_bootstrap(work_request, linked_slice, creation, handoff_opts)

        {:ok,
         %{
           work_request: work_request,
           planned_slice: linked_slice,
           creation: creation,
           worker_bootstrap: worker_bootstrap
         }}

      {:error, reason} ->
        cleanup_after_link_failure(repo, creation, reason, opts)
    end
  end

  defp link_planned_slice(repo, work_request_id, planned_slice_id, work_package_id, opts) do
    link_fun = Keyword.get(opts, :link_planned_slice, &Repository.dispatch_planned_slice/5)
    link_fun.(repo, work_request_id, planned_slice_id, "approved", work_package_id)
  rescue
    error -> {:error, {:link_failed, Exception.message(error)}}
  end

  defp cleanup_after_link_failure(repo, creation, reason, opts) do
    recovery = recovery_payload(creation)
    cleanup_fun = Keyword.get(opts, :cleanup_created_work_package, &CreateWork.cleanup_created_work_package/2)

    case cleanup_fun.(repo, creation.work_package.id) do
      :ok ->
        cleanup = %{ledger: :deleted}
        {:error, {:dispatch_link_failed, reason, Map.put(recovery, :cleanup, cleanup)}}

      {:ok, _result} ->
        cleanup = %{ledger: :deleted}
        {:error, {:dispatch_link_failed, reason, Map.put(recovery, :cleanup, cleanup)}}

      {:error, ledger_cleanup_reason} ->
        cleanup = %{ledger: {:cleanup_failed, ledger_cleanup_reason}}
        {:error, {:dispatch_link_failed, reason, Map.put(recovery, :cleanup, cleanup)}}
    end
  end

  defp recovery_payload(%{work_package: work_package, worker_grant: worker_grant}) do
    %{
      work_package_id: work_package.id,
      worker_grant_id: Map.get(worker_grant, :id) || Map.get(worker_grant, "id"),
      worker_grant_display_key: Map.get(worker_grant, :display_key) || Map.get(worker_grant, "display_key")
    }
  end

  defp ledger_bootstrap(nil), do: nil
  defp ledger_bootstrap(database), do: %{database: database}

  defp supported_worker_skill_sets do
    [
      @preferred_worker_skill_set,
      [@default_worker_skill, @repo_work_package_skill]
    ]
  end

  defp worker_launch_prompt(
         %WorkRequest{} = work_request,
         %PlannedSlice{} = planned_slice,
         work_package,
         claim_arguments,
         ledger_database
       ) do
    title = prompt_data(work_package.title)
    work_package_id = prompt_data(work_package.id)
    work_request_id = prompt_data(work_request.id)
    planned_slice_id = prompt_data(planned_slice.id)
    ledger_line = ledger_prompt_line(ledger_database)

    claim_arguments =
      claim_arguments
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Jason.encode!()

    """
    WorkPackage #{work_package_id}: #{title}
    Worker: WorkPackage #{work_package_id}.
    Audit: WorkRequest #{work_request_id}; planned slice #{planned_slice_id}.

    Skills: `#{@mcp_worker_skill}` + `#{@mcp_work_package_skill}`; fallback `#{@default_worker_skill}` + `#{@repo_work_package_skill}`.
    #{ledger_line}

    Start: call `claim_local_assignment` with #{claim_arguments}; stop on paused/owned/scope failure.
    Then `get_current_assignment()`, `read_context()`, `read_task_plan()`, virtual resources, and update the task plan before coding.
    Track progress/findings/blockers/review evidence; ready only after acceptance/tests/review gates.
    Scope: only this WorkPackage. Planned slice is audit context, not a worker target. Never request, print, paste, or commit raw secrets.
    Stop if MCP, claim, assignment, context, or scope is missing.
    """
    |> String.trim()
  end

  defp ledger_prompt_line(nil), do: "Use the active MCP ledger."

  defp ledger_prompt_line(database) do
    "Set MCP ledger #{prompt_data(database)} before claiming."
  end

  defp prompt_data(nil), do: ~s("")
  defp prompt_data(value), do: value |> to_string() |> Jason.encode!()

  defp engineering_scope(%WorkRequest{} = work_request, %PlannedSlice{} = planned_slice) do
    [
      String.trim(planned_slice.goal || ""),
      list_section("Validation steps", planned_slice.validation_steps),
      list_section("Forbidden file globs", forbidden_file_globs(work_request, planned_slice)),
      list_section("Stop conditions", planned_slice.stop_conditions)
    ]
    |> Enum.reject(&blank?/1)
    |> Enum.join("\n\n")
  end

  defp forbidden_file_globs(%WorkRequest{} = work_request, %PlannedSlice{} = planned_slice) do
    (planned_slice.forbidden_file_globs || [])
    |> Enum.concat(forbidden_paths_constraint(work_request.constraints || %{}))
    |> Enum.uniq()
  end

  defp forbidden_paths_constraint(constraints) when is_map(constraints) do
    case Map.get(constraints, "forbidden_paths") do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _value -> []
    end
  end

  defp list_section(_title, []), do: nil
  defp list_section(_title, nil), do: nil

  defp list_section(title, values) when is_list(values) do
    values =
      values
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&blank?/1)

    if values == [] do
      nil
    else
      title <> ":\n" <> Enum.map_join(values, "\n", &("- " <> &1))
    end
  end

  defp planned_slice_linkage_payload(%PlannedSlice{} = planned_slice) do
    %{
      work_request_id: planned_slice.work_request_id,
      planned_slice_id: planned_slice.id,
      status: planned_slice.status,
      work_package_id: planned_slice.work_package_id,
      dispatched_at: timestamp(planned_slice.dispatched_at)
    }
  end

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(nil), do: nil

  defp nonblank_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp nonblank_or_nil(_value), do: nil

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp blank?(value), do: is_nil(value) or value == ""
end
