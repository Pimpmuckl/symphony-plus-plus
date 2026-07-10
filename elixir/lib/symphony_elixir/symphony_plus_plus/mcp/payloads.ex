defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Payloads do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ProgressEvents
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @type timestamp_value :: DateTime.t() | NaiveDateTime.t() | nil

  @spec optional_payload(map()) :: {:ok, map()} | {:tool_error, String.t()}
  def optional_payload(arguments) do
    case Map.get(arguments, "payload", %{}) do
      payload when is_map(payload) -> {:ok, payload}
      _payload -> {:tool_error, "invalid_payload"}
    end
  end

  @spec guidance_request_cards([GuidanceRequest.t()]) :: [map()]
  def guidance_request_cards(guidance_requests) do
    Enum.map(guidance_requests, &guidance_request_card_payload/1)
  end

  @spec comment_payload(Comment.t()) :: map()
  def comment_payload(%Comment{} = comment) do
    %{
      "id" => comment.id,
      "target_kind" => comment.target_kind,
      "target_id" => comment.target_id,
      "body" => Redactor.redact_text(comment.body),
      "source_type" => comment.source_type,
      "author_name" => Redactor.redact_text(comment.author_name),
      "status" => comment.status,
      "resolved_by" => Redactor.redact_text(comment.resolved_by),
      "resolved_source_type" => comment.resolved_source_type,
      "resolved_at" => timestamp(comment.resolved_at),
      "resolution_note" => Redactor.redact_text(comment.resolution_note),
      "inserted_at" => timestamp(comment.inserted_at),
      "updated_at" => timestamp(comment.updated_at)
    }
  end

  @spec guidance_request_card_payload(GuidanceRequest.t()) :: map()
  def guidance_request_card_payload(%GuidanceRequest{} = guidance_request) do
    %{
      "id" => guidance_request.id,
      "work_package_id" => guidance_request.work_package_id,
      "summary" => Redactor.redact_text(guidance_request.summary),
      "status" => guidance_request.status,
      "requested_by" => guidance_request.requested_by,
      "answered_by" => guidance_request.answered_by,
      "blocker_id" => guidance_request.blocker_id,
      "inserted_at" => timestamp(guidance_request.inserted_at),
      "updated_at" => timestamp(guidance_request.updated_at)
    }
  end

  @spec guidance_request_payload(GuidanceRequest.t()) :: map()
  def guidance_request_payload(%GuidanceRequest{} = guidance_request) do
    %{
      "id" => guidance_request.id,
      "work_package_id" => guidance_request.work_package_id,
      "summary" => Redactor.redact_text(guidance_request.summary),
      "question" => Redactor.redact_text(guidance_request.question),
      "context" => Redactor.redact_text(guidance_request.context),
      "status" => guidance_request.status,
      "requested_by" => guidance_request.requested_by,
      "answer" => Redactor.redact_text(guidance_request.answer),
      "answered_by" => guidance_request.answered_by,
      "answered_at" => timestamp(guidance_request.answered_at),
      "human_info_reason" => Redactor.redact_text(guidance_request.human_info_reason),
      "recommended_language" => Redactor.redact_text(guidance_request.recommended_language),
      "decision_prompt" => Redactor.redact_output(guidance_request.decision_prompt),
      "blocker_id" => guidance_request.blocker_id,
      "inserted_at" => timestamp(guidance_request.inserted_at),
      "updated_at" => timestamp(guidance_request.updated_at)
    }
  end

  @spec dispatch_slice_payload(map(), map()) :: map()
  def dispatch_slice_payload(
        %{
          work_request: %WorkRequest{} = work_request,
          planned_slice: %PlannedSlice{} = planned_slice,
          creation: creation
        } = dispatch,
        scope
      ) do
    worker_bootstrap =
      dispatch_or_creation_value(dispatch, creation, :worker_bootstrap)
      |> dispatch_worker_bootstrap_payload()

    %{
      "coordinates" => worker_bootstrap && Map.get(worker_bootstrap, "coordinates"),
      "work_request" => %{"id" => work_request.id},
      "planned_slice" => %{
        "id" => planned_slice.id,
        "status" => planned_slice.status,
        "work_package_id" => planned_slice.work_package_id,
        "dispatched_at" => timestamp(planned_slice.dispatched_at)
      },
      "work_package" => dispatch_work_package_payload(Map.fetch!(creation, :work_package)),
      "worker_bootstrap" => worker_bootstrap,
      "worker_grant" => dispatch_worker_grant_payload(Map.fetch!(creation, :worker_grant)),
      "scope" => scope,
      "status" => %{"planned_slice_status" => planned_slice.status}
    }
  end

  @spec dispatch_work_package_payload(WorkPackage.t() | map()) :: map()
  def dispatch_work_package_payload(%WorkPackage{} = work_package) do
    work_package
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> json_safe_payload()
    |> Redactor.redact_output()
  end

  def dispatch_work_package_payload(work_package) when is_map(work_package) do
    work_package
    |> json_safe_payload()
    |> Redactor.redact_output()
  end

  @spec dispatch_worker_grant_payload(map()) :: map()
  def dispatch_worker_grant_payload(worker_grant) when is_map(worker_grant) do
    worker_grant
    |> json_safe_payload()
    |> Map.drop(["display_key", "secret", "secret_hash", "secret_handoff", "secret_returned_once", "worker_secret_handoff"])
    |> Map.put("secret_in_response", false)
  end

  @spec dispatch_worker_bootstrap_payload(map() | nil) :: map() | nil
  def dispatch_worker_bootstrap_payload(nil), do: nil

  def dispatch_worker_bootstrap_payload(bootstrap) when is_map(bootstrap) do
    bootstrap
    |> json_safe_payload()
    |> Redactor.redact_output()
  end

  @spec dispatch_link_recovery_payload(map()) :: map()
  def dispatch_link_recovery_payload(recovery) when is_map(recovery) do
    %{}
    |> put_optional_recovery_value("work_package_id", recovery_value(recovery, :work_package_id))
    |> put_optional_recovery_value("worker_grant_id", recovery_value(recovery, :worker_grant_id))
    |> put_optional_recovery_value("cleanup", safe_recovery_value(recovery_value(recovery, :cleanup)))
  end

  @spec put_optional_recovery_value(map(), String.t(), term()) :: map()
  def put_optional_recovery_value(payload, _key, nil), do: payload
  def put_optional_recovery_value(payload, key, value), do: Map.put(payload, key, value)

  @doc false
  @spec mcp_timestamp(timestamp_value()) :: String.t() | nil
  def mcp_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  def mcp_timestamp(%NaiveDateTime{} = timestamp) do
    timestamp
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_iso8601()
  end

  def mcp_timestamp(nil), do: nil

  @spec timestamp(timestamp_value()) :: String.t() | nil
  def timestamp(timestamp), do: mcp_timestamp(timestamp)

  @spec worktree_lifecycle_payload(map(), map(), term()) :: map()
  def worktree_lifecycle_payload(result, scope, audit_event) do
    %{
      "work_package" => work_package_worktree_payload(result.work_package),
      "worktree" => %{
        "status" => result.status,
        "path" => Redactor.redact_text(result.worktree_path),
        "target_repo_root" => Redactor.redact_text(result.target_repo_root || result.repo_root),
        "branch" => result.branch,
        "base_branch" => result.base_branch
      },
      "worker_launch" => worktree_worker_launch_payload(result),
      "audit_event" => ProgressEvents.payload(audit_event),
      "scope" => scope
    }
  end

  @spec worktree_worker_launch_payload(map()) :: map() | nil
  def worktree_worker_launch_payload(%{worktree_path: worktree_path, branch: branch, base_branch: base_branch})
      when is_binary(worktree_path) and is_binary(branch) and is_binary(base_branch) do
    %{
      "workspace_path" => Redactor.redact_text(worktree_path),
      "branch" => branch,
      "base_branch" => base_branch,
      "instruction" => "Use this worktree only for the assigned WorkPackage."
    }
  end

  def worktree_worker_launch_payload(_result), do: nil

  @spec work_package_worktree_payload(WorkPackage.t()) :: map()
  def work_package_worktree_payload(%WorkPackage{} = work_package) do
    work_package
    |> work_package_payload()
    |> Map.put("worktree_path", Redactor.redact_text(work_package.worktree_path))
  end

  @spec work_package_payload(WorkPackage.t()) :: map()
  def work_package_payload(%WorkPackage{} = work_package) do
    %{"id" => work_package.id, "kind" => work_package.kind, "status" => work_package.status}
  end

  @spec child_work_package_payload(WorkPackage.t()) :: map()
  def child_work_package_payload(%WorkPackage{} = work_package) do
    work_package
    |> work_package_payload()
    |> Map.merge(%{
      "acceptance_criteria" => work_package.acceptance_criteria || [],
      "allowed_file_globs" => work_package.allowed_file_globs || [],
      "base_branch" => work_package.base_branch,
      "parent_id" => work_package.parent_id,
      "phase_id" => work_package.phase_id,
      "policy_template" => work_package.policy_template,
      "repo" => work_package.repo,
      "title" => work_package.title
    })
  end

  @spec json_safe_payload(term()) :: term()
  def json_safe_payload(payload) do
    payload
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp dispatch_or_creation_value(dispatch, creation, key) when is_atom(key) do
    Map.get(dispatch, key) || map_get(creation, key)
  end

  defp map_get(map, key) when is_map(map) and is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
  defp map_get(_value, _key), do: nil

  defp recovery_value(recovery, key) do
    Map.get(recovery, key) || Map.get(recovery, to_string(key))
  end

  defp safe_recovery_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, map_value} -> {to_string(key), safe_recovery_value(map_value)} end)
    |> Map.new()
  end

  defp safe_recovery_value(value) when is_list(value), do: Enum.map(value, &safe_recovery_value/1)
  defp safe_recovery_value(value) when is_atom(value), do: Atom.to_string(value)
  defp safe_recovery_value(value) when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: value
  defp safe_recovery_value(value), do: inspect(value)
end
