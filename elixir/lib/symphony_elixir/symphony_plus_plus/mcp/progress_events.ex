defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ProgressEvents do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolResult
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Service, as: PlanningService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @finding_replay_retry_attempts 50
  @ready_evidence_tools [
    "abandon",
    "append_finding",
    "append_progress",
    "attach_branch",
    "attach_pr",
    "sync_pr",
    "report_blocker",
    "request_scope_expansion",
    "resolve_blocker",
    "submit_review_package",
    "complete_review"
  ]

  @type repo :: module()
  @type mcp_error :: {:error, integer(), String.t(), map()}
  @type worker_result :: {:ok, map()} | {:tool_error, term()} | {:error, term()} | mcp_error()

  @spec append_or_replay(repo(), Session.t(), map(), String.t(), String.t()) :: worker_result()
  def append_or_replay(repo, %Session{} = session, attrs, idempotency_key, tool) do
    case existing(repo, session, idempotency_key) do
      {:ok, event} -> replay(repo, session, event, attrs, tool)
      {:error, :not_found} -> append_new_or_replay(repo, session, attrs, idempotency_key, tool)
      {:error, reason} -> worker_error(reason, tool)
    end
  end

  @spec append_metadata(repo(), Session.t(), map(), String.t(), String.t(), map()) :: worker_result()
  def append_metadata(repo, %Session{} = session, arguments, tool, status, payload) do
    case metadata_attrs(session, arguments, tool, status, payload) do
      {:ok, idempotency_key, attrs} -> append_or_replay(repo, session, attrs, idempotency_key, tool)
      {:tool_error, reason} -> {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
    end
  end

  @spec replay_metadata(repo(), Session.t(), map(), String.t(), String.t(), map(), [ProgressEvent.t()] | nil) ::
          {:ok, map()} | :not_found | mcp_error()
  def replay_metadata(repo, %Session{} = session, arguments, tool, status, payload, progress_events) do
    case metadata_attrs(session, arguments, tool, status, payload) do
      {:ok, idempotency_key, attrs} ->
        case existing_metadata_event(repo, session, idempotency_key, tool, progress_events) do
          {:ok, event} -> replay(repo, session, event, attrs, tool)
          {:error, :not_found} -> :not_found
          {:error, reason} -> worker_error(reason, tool)
        end

      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}
    end
  end

  @spec replay?(repo(), Session.t(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def replay?(repo, %Session{} = session, idempotency_key) do
    case existing(repo, session, idempotency_key) do
      {:ok, %ProgressEvent{}} -> {:ok, true}
      {:error, :not_found} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec replay_existing(repo(), Session.t(), ProgressEvent.t(), map(), String.t()) :: worker_result()
  def replay_existing(repo, %Session{} = session, %ProgressEvent{} = event, attrs, tool) do
    replay(repo, session, event, attrs, tool)
  end

  @spec existing(repo(), Session.t(), String.t()) :: {:ok, ProgressEvent.t()} | {:error, term()}
  def existing(repo, %Session{} = session, idempotency_key) do
    case PlanningRepository.get_progress_event_by_idempotency_key(
           repo,
           Session.work_package_id(session),
           idempotency_key,
           session.assignment.grant_id
         ) do
      {:ok, event} -> {:ok, event}
      {:error, :not_found} -> existing_work_package_progress_event(repo, session, idempotency_key)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec existing_for_work_package(repo(), String.t(), String.t()) :: {:ok, ProgressEvent.t()} | {:error, term()}
  def existing_for_work_package(repo, work_package_id, idempotency_key) do
    existing_work_package_progress_event(repo, work_package_id, idempotency_key)
  end

  @spec matching([ProgressEvent.t()], String.t()) :: {:ok, ProgressEvent.t()} | {:error, :not_found}
  def matching(progress_events, idempotency_key) do
    matching_progress_event(progress_events, idempotency_key)
  end

  @spec request_scope_expansion_payload(repo(), Session.t()) :: {:ok, map()} | {:error, term()}
  def request_scope_expansion_payload(repo, %Session{} = session) do
    payload = %{
      "type" => "scope_expansion_request",
      "source_tool" => "request_scope_expansion",
      "approved" => false
    }

    case WorkPackageRepository.get(repo, session.assignment.work_package_id) do
      {:ok, %WorkPackage{kind: "investigation"} = work_package} ->
        {:ok, Map.put(payload, "recommendation_artifact_id", recommendation_artifact_id(work_package.id))}

      {:ok, %WorkPackage{}} ->
        {:ok, payload}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec metadata_attrs(Session.t(), map(), String.t(), String.t(), map()) ::
          {:ok, String.t(), map()} | {:tool_error, term()}
  def metadata_attrs(%Session{} = session, arguments, tool, status, payload) do
    payload = Map.put(payload, "source_tool", tool)

    arguments =
      Map.put_new(arguments, "summary", status)
      |> Map.put_new("status", status)
      |> Map.put_new("idempotency_key", metadata_idempotency_key(payload))
      |> canonical_metadata_event_status(tool, status)

    with {:ok, summary} <- required_argument(arguments, "summary"),
         {:ok, idempotency_key} <- required_argument(arguments, "idempotency_key"),
         {:ok, caller_payload} <- optional_payload(arguments),
         :ok <- validate_metadata_caller_payload(tool, caller_payload) do
      idempotency_key = scoped_idempotency_key(tool, String.trim(idempotency_key), session)

      {:ok, idempotency_key,
       %{
         "summary" => summary,
         "body" => optional_argument(arguments, "body", nil),
         "status" => optional_argument(arguments, "status", "recorded"),
         "idempotency_key" => idempotency_key,
         "payload" => merge_payload(tool, caller_payload, payload)
       }}
    end
  end

  @spec scoped_idempotency_key(String.t(), String.t(), Session.t()) :: String.t()
  def scoped_idempotency_key("submit_review_package", idempotency_key, %Session{} = session) do
    ["submit_review_package", session.assignment.work_package_id, idempotency_key] |> Enum.join(":")
  end

  def scoped_idempotency_key("complete_review", idempotency_key, %Session{} = session) do
    ["complete_review", session.assignment.work_package_id, idempotency_key] |> Enum.join(":")
  end

  def scoped_idempotency_key(tool, idempotency_key, %Session{} = session) when tool in ["attach_branch", "attach_pr", "sync_pr"] do
    [tool, session.assignment.work_package_id, idempotency_key] |> Enum.join(":")
  end

  def scoped_idempotency_key(tool, idempotency_key, %Session{}), do: tool <> ":" <> idempotency_key

  @spec metadata_idempotency_key(map()) :: String.t()
  def metadata_idempotency_key(payload) do
    "mcp:" <> Map.get(payload, "type", "metadata") <> ":" <> Base.url_encode64(:erlang.term_to_binary(payload), padding: false)
  end

  @spec merge_payload(String.t(), map(), map()) :: map()
  def merge_payload("append_progress", caller_payload, tool_payload) do
    caller_payload
    |> drop_protected_append_progress_payload()
    |> Map.merge(tool_payload)
  end

  def merge_payload("complete_review", _caller_payload, tool_payload), do: tool_payload

  def merge_payload(_tool, caller_payload, tool_payload) when tool_payload == %{} do
    Map.drop(caller_payload, ["source_tool"])
  end

  def merge_payload(_tool, caller_payload, %{"type" => "scope_expansion_request", "source_tool" => "request_scope_expansion"} = tool_payload) do
    caller_payload
    |> Map.drop(["source_tool", "recommendation_artifact_id"])
    |> Map.merge(tool_payload)
  end

  def merge_payload(_tool, caller_payload, tool_payload), do: Map.merge(caller_payload, tool_payload)

  @spec recommendation_artifact_id(String.t()) :: String.t()
  def recommendation_artifact_id(work_package_id) do
    material = [work_package_id, "recommendation", "recommendation.md"] |> Enum.join(":")
    "artifact_" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  @spec payload(ProgressEvent.t() | nil) :: map() | nil
  def payload(%ProgressEvent{} = event) do
    %{
      "id" => event.id,
      "summary" => Redactor.redact_text(event.summary),
      "status" => Redactor.redact_text(event.status),
      "idempotency_key" => Redactor.redact_text(event.idempotency_key),
      "payload" => Redactor.redact_output(event.payload || %{})
    }
  end

  def payload(nil), do: nil

  defp append_new_or_replay(repo, %Session{} = session, attrs, idempotency_key, tool) do
    transaction_fun = fn ->
      with :ok <- PlanningService.require_valid_assignment(repo, session.assignment),
           :ok <- reject_ready_evidence_mutation(repo, session, tool),
           {:ok, event} <- PlanningService.append_authenticated_progress_event(repo, session.assignment, attrs),
           :ok <- append_investigation_recommendation_artifact(repo, session, tool, event) do
        {:ok, event}
      end
    end

    case run_worker_transaction(repo, transaction_fun) do
      {:ok, event} ->
        {:ok, ToolResult.agent_tool_result(%{"progress_event" => payload(event)})}

      {:tool_error, reason} ->
        {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason}}

      {:error, :idempotency_key_conflict} ->
        replay_with_retry(repo, session, attrs, idempotency_key, tool, progress_replay_retry_attempts())

      {:error, reason} ->
        worker_error(reason, tool)
    end
  end

  defp append_investigation_recommendation_artifact(repo, %Session{} = session, "request_scope_expansion", %ProgressEvent{} = event) do
    if Map.has_key?(event.payload || %{}, "recommendation_artifact_id") do
      append_recommendation_artifact(repo, session, event)
    else
      :ok
    end
  end

  defp append_investigation_recommendation_artifact(_repo, %Session{}, _tool, %ProgressEvent{}), do: :ok

  defp append_recommendation_artifact(repo, %Session{} = session, %ProgressEvent{}) do
    work_package_id = session.assignment.work_package_id

    attrs = %{
      "id" => recommendation_artifact_id(work_package_id),
      "work_package_id" => work_package_id,
      "path" => "recommendation.md",
      "title" => "Investigation recommendation",
      "kind" => "recommendation"
    }

    append_recommendation_artifact(attrs, repo)
  end

  defp append_recommendation_artifact(attrs, repo) do
    case PlanningRepository.get_artifact(repo, attrs["id"]) do
      {:ok, nil} ->
        case PlanningService.append_artifact(repo, attrs) do
          {:ok, _artifact} -> :ok
          {:error, :id_already_exists} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, %Artifact{} = artifact} ->
        repair_recommendation_artifact(repo, attrs, artifact)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repair_recommendation_artifact(repo, attrs, %Artifact{} = artifact) do
    if artifact.work_package_id == attrs["work_package_id"] do
      case PlanningRepository.update_artifact(repo, artifact, recommendation_artifact_repair_attrs(attrs, artifact)) do
        {:ok, _artifact} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :id_already_exists}
    end
  end

  defp recommendation_artifact_repair_attrs(attrs, %Artifact{} = artifact) do
    %{
      work_package_id: attrs["work_package_id"],
      path: attrs["path"],
      title: attrs["title"],
      kind: attrs["kind"],
      uri: repaired_recommendation_artifact_uri(attrs, artifact)
    }
  end

  defp repaired_recommendation_artifact_uri(%{"uri" => uri}, %Artifact{}) when not is_nil(uri), do: uri

  defp repaired_recommendation_artifact_uri(attrs, %Artifact{} = artifact) do
    if artifact.work_package_id == attrs["work_package_id"] and artifact.path == attrs["path"] and artifact.title == attrs["title"] and
         artifact.kind == attrs["kind"] do
      artifact.uri
    else
      nil
    end
  end

  @spec reject_ready_evidence_mutation(repo(), Session.t(), String.t()) ::
          :ok | {:tool_error, term()} | {:error, term()}
  def reject_ready_evidence_mutation(repo, %Session{} = session, tool) when tool in @ready_evidence_tools do
    work_package_id = Session.work_package_id(session)

    with :ok <- lock_work_package(repo, work_package_id),
         {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
      reject_ready_work_package(work_package)
    end
  end

  def reject_ready_evidence_mutation(_repo, %Session{}, _tool), do: :ok

  defp reject_ready_work_package(%WorkPackage{kind: "phase_child", status: status}) when status in ["merging_into_phase", "merged_into_phase"] do
    {:tool_error, "child_under_architect_control"}
  end

  defp reject_ready_work_package(%WorkPackage{status: status}) when status in ["ready_for_merge", "ready_for_human_merge", "ready_for_architect_merge"] do
    {:tool_error, "already_ready"}
  end

  defp reject_ready_work_package(%WorkPackage{}), do: :ok

  defp replay_with_retry(repo, %Session{} = session, attrs, idempotency_key, tool, attempts_left) do
    retry_fun = fn ->
      replay_with_retry(repo, session, attrs, idempotency_key, tool, attempts_left - 1)
    end

    repo
    |> replay(session, attrs, idempotency_key, tool)
    |> retry_missing(retry_fun, attempts_left)
  end

  defp replay(repo, %Session{} = session, %ProgressEvent{} = event, attrs, tool) do
    case PlanningService.require_valid_assignment(repo, session.assignment) do
      :ok -> replay_matching(event, attrs, tool)
      {:error, reason} -> worker_error(reason, tool)
    end
  end

  defp replay(repo, %Session{} = session, attrs, idempotency_key, tool) do
    case existing(repo, session, idempotency_key) do
      {:ok, event} -> replay(repo, session, event, attrs, tool)
      {:error, reason} -> worker_error(reason, tool)
    end
  end

  defp existing_metadata_event(_repo, %Session{}, idempotency_key, "submit_review_package", progress_events) when is_list(progress_events) do
    case Enum.find(progress_events, fn event -> event.idempotency_key == idempotency_key end) do
      %ProgressEvent{} = event -> {:ok, event}
      nil -> {:error, :not_found}
    end
  end

  defp existing_metadata_event(repo, %Session{} = session, idempotency_key, _tool, _progress_events) do
    PlanningRepository.get_progress_event_by_idempotency_key(
      repo,
      Session.work_package_id(session),
      idempotency_key,
      session.assignment.grant_id
    )
  end

  defp existing_work_package_progress_event(repo, %Session{} = session, idempotency_key) do
    existing_work_package_progress_event(repo, Session.work_package_id(session), idempotency_key)
  end

  defp existing_work_package_progress_event(repo, work_package_id, idempotency_key) do
    case PlanningRepository.list_progress_events(repo, work_package_id) do
      {:ok, progress_events} -> matching_progress_event(progress_events, idempotency_key)
      {:error, reason} -> {:error, reason}
    end
  end

  defp matching_progress_event(progress_events, idempotency_key) do
    case Enum.find(progress_events, fn event -> event.idempotency_key == idempotency_key end) do
      %ProgressEvent{} = event -> {:ok, event}
      nil -> {:error, :not_found}
    end
  end

  defp retry_missing({:error, _code, _message, %{"reason" => "not_found"}}, retry_fun, attempts_left) when attempts_left > 0 do
    Process.sleep(5)
    retry_fun.()
  end

  defp retry_missing(result, _retry_fun, _attempts_left), do: result

  defp replay_matching(%ProgressEvent{} = event, attrs, tool) do
    if progress_replay_matches?(event, attrs) do
      {:ok, ToolResult.agent_tool_result(%{"progress_event" => payload(event)})}
    else
      {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => "idempotency_conflict"}}
    end
  end

  defp progress_replay_matches?(%ProgressEvent{} = event, attrs) do
    normalized_payload = normalized_progress_payload(event, attrs)

    event.summary == Map.get(attrs, "summary") and
      event.body == Map.get(attrs, "body") and
      event.status == Map.get(attrs, "status") and
      progress_payload_replay_matches?(event.payload, normalized_payload)
  end

  defp progress_payload_replay_matches?(%{"type" => "scope_expansion_request", "source_tool" => "request_scope_expansion"} = existing, normalized) do
    existing == normalized or legacy_scope_expansion_replay_matches?(existing, normalized)
  end

  defp progress_payload_replay_matches?(%{"type" => "pr", "source_tool" => "attach_pr"} = existing, %{"type" => "pr", "source_tool" => "attach_pr"} = normalized) do
    existing == normalized or legacy_attach_pr_replay_matches?(existing, normalized)
  end

  defp progress_payload_replay_matches?(existing, normalized), do: existing == normalized

  defp legacy_scope_expansion_replay_matches?(existing, normalized) do
    legacy_normalized =
      case Map.fetch(existing, "recommendation_artifact_id") do
        {:ok, artifact_id} -> Map.put(normalized, "recommendation_artifact_id", artifact_id)
        :error -> Map.delete(normalized, "recommendation_artifact_id")
      end

    existing == legacy_normalized
  end

  defp legacy_attach_pr_replay_matches?(existing, normalized) do
    existing == Map.take(normalized, ["type", "source_tool", "url", "head_sha"])
  end

  defp normalized_progress_payload(%ProgressEvent{} = event, attrs) do
    attrs
    |> Map.merge(%{
      "id" => "replay_probe",
      "work_package_id" => event.work_package_id,
      "sequence" => 1,
      "created_at" => event.created_at || DateTime.utc_now(:microsecond)
    })
    |> ProgressEvent.create_changeset(trusted_audit_metadata: true)
    |> Ecto.Changeset.apply_changes()
    |> Map.get(:payload)
  end

  defp canonical_metadata_event_status(arguments, _tool, _status), do: arguments

  defp validate_metadata_caller_payload("complete_review", caller_payload) when map_size(caller_payload) == 0, do: :ok
  defp validate_metadata_caller_payload("complete_review", _caller_payload), do: {:tool_error, "unexpected_payload"}
  defp validate_metadata_caller_payload(_tool, _caller_payload), do: :ok

  defp drop_protected_append_progress_payload(%{"type" => type} = caller_payload) when type in ["scope_expansion_request", "scope_expansion_approval"] do
    Map.drop(caller_payload, [
      "type",
      "source_tool",
      "recommendation_artifact_id",
      "approved",
      "requested_file_globs",
      "approved_file_globs",
      "allowed_file_globs",
      "previous_allowed_file_globs",
      "request_id"
    ])
  end

  defp drop_protected_append_progress_payload(caller_payload) do
    Map.drop(caller_payload, [
      "source_tool",
      "recommendation_artifact_id",
      "approved",
      "requested_file_globs",
      "approved_file_globs",
      "allowed_file_globs",
      "previous_allowed_file_globs",
      "request_id"
    ])
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

  defp optional_payload(arguments) do
    case Map.get(arguments, "payload", %{}) do
      payload when is_map(payload) -> {:ok, payload}
      _payload -> {:tool_error, "invalid_payload"}
    end
  end

  defp optional_argument(arguments, key, default) do
    case Map.get(arguments, key, default) do
      value when is_binary(value) -> if String.trim(value) == "", do: default, else: value
      nil -> default
      value -> value
    end
  end

  defp run_worker_transaction(repo, fun) do
    case repo.transaction(fn -> rollback_worker_transaction_result(repo, fun.()) end) do
      {:ok, result} -> {:ok, result}
      {:error, {:tool_error, reason}} -> {:tool_error, reason}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rollback_worker_transaction_result(_repo, {:ok, result}), do: result
  defp rollback_worker_transaction_result(repo, {:tool_error, reason}), do: repo.rollback({:tool_error, reason})

  defp rollback_worker_transaction_result(repo, {:error, reason}), do: repo.rollback({:error, reason})

  defp lock_work_package(repo, work_package_id) do
    query = from(work_package in WorkPackage, where: work_package.id == ^work_package_id)

    case repo.update_all(query, set: [id: work_package_id]) do
      {1, _rows} -> :ok
      {0, _rows} -> {:error, :not_found}
    end
  end

  defp progress_replay_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_finding_replay_retry_attempts, @finding_replay_retry_attempts)
    |> max(0)
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

  defp auth_error(:unauthorized, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => "missing_session"}}
  defp auth_error({:unauthorized, reason}, resource), do: {:error, -32_001, "Unauthorized", %{"resource" => resource, "reason" => reason_text(reason)}}
  defp auth_error({:service_unavailable, reason}, resource), do: service_error(reason, resource)
  defp auth_error(:forbidden, resource), do: {:error, -32_003, "Forbidden", %{"resource" => resource, "reason" => "outside_session_scope"}}
  defp service_error(_reason, resource), do: {:error, -32_000, "Server error", %{"resource" => resource, "reason" => "ledger_unavailable"}}
  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
