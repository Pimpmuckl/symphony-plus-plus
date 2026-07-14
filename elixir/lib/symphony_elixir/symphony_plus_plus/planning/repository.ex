defmodule SymphonyElixir.SymphonyPlusPlus.Planning.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion, as: WorkRequestCompletion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  @default_append_retry_attempts 200
  @default_state_read_retry_attempts 50
  @state_item_limit 100

  @type repo :: module()
  @type planning_record :: PlanNode.t() | Finding.t() | ProgressEvent.t() | Artifact.t()
  @type error ::
          :assignment_mismatch
          | :assignment_revoked
          | :expired
          | :conflicting_key_forms
          | :idempotency_scope_conflict
          | :database_busy
          | :id_already_exists
          | :idempotency_key_conflict
          | :not_found
          | :sequence_conflict
          | {:constraint_failed, String.t()}
          | {:migration_failed, term()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec migrate(repo()) :: :ok | {:error, error()}
  def migrate(repo) when is_atom(repo) do
    Ecto.Migrator.run(repo, Migrations.all(), :up, all: true, log: false)
    :ok
  rescue
    error -> {:error, {:migration_failed, error}}
  end

  @spec append_plan_node(repo(), map()) :: {:ok, PlanNode.t()} | {:error, error()}
  def append_plan_node(repo, attrs) when is_atom(repo) and is_map(attrs) do
    insert_with_allocated_value(
      repo,
      drop_ordering(attrs, :position),
      PlanNode,
      :position,
      &PlanNode.create_changeset/1
    )
  end

  @spec append_finding(repo(), map()) :: {:ok, Finding.t()} | {:error, error()}
  def append_finding(repo, attrs) when is_atom(repo) and is_map(attrs) do
    insert_with_allocated_value(repo, drop_ordering(attrs, :sequence), Finding, :sequence, &Finding.create_changeset/1)
  end

  @spec append_progress_event(repo(), map()) :: {:ok, ProgressEvent.t()} | {:error, error()}
  def append_progress_event(repo, attrs) when is_atom(repo) and is_map(attrs) do
    repo.transaction(fn ->
      changeset_fun = &ProgressEvent.create_changeset/1
      opts = [trusted_audit_metadata: false]

      case append_progress_event_in_transaction(repo, attrs, changeset_fun, opts) do
        {:ok, event} -> event
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec append_audit_progress_event(repo(), Assignment.t(), map()) :: {:ok, ProgressEvent.t()} | {:error, error()}
  @spec append_audit_progress_event(repo(), Assignment.t(), map(), keyword()) ::
          {:ok, ProgressEvent.t()} | {:error, error()}
  def append_audit_progress_event(repo, assignment, attrs) do
    append_audit_progress_event(repo, assignment, attrs, [])
  end

  @spec append_audit_progress_event(repo(), Assignment.t(), map(), keyword()) ::
          {:ok, ProgressEvent.t()} | {:error, error()}
  def append_audit_progress_event(repo, %Assignment{} = assignment, attrs, opts)
      when is_atom(repo) and is_map(attrs) and is_list(opts) do
    append_audit_progress_event_for_work_package(repo, assignment, assignment.work_package_id, attrs, opts)
  end

  @spec append_audit_progress_event_for_work_package(repo(), Assignment.t(), String.t(), map()) ::
          {:ok, ProgressEvent.t()} | {:error, error()}
  def append_audit_progress_event_for_work_package(repo, assignment, work_package_id, attrs) do
    append_audit_progress_event_for_work_package(repo, assignment, work_package_id, attrs, [])
  end

  @spec append_audit_progress_event_for_work_package(repo(), Assignment.t(), String.t(), map(), keyword()) ::
          {:ok, ProgressEvent.t()} | {:error, error()}
  def append_audit_progress_event_for_work_package(repo, %Assignment{} = assignment, work_package_id, attrs, opts)
      when is_atom(repo) and is_binary(work_package_id) and is_map(attrs) and is_list(opts) do
    repo.transaction(fn ->
      attrs = audit_attrs(assignment, attrs, opts)
      attrs = Map.put(attrs, "work_package_id", work_package_id)

      with :not_found <- existing_progress_event_by_idempotency_key_with_retry(repo, attrs, append_retry_attempts()),
           :ok <- lock_valid_assignment(repo, assignment),
           {:ok, event} <-
             append_progress_event_in_transaction(
               repo,
               attrs,
               &ProgressEvent.create_changeset(&1, trusted_audit_metadata: true),
               trusted_audit_metadata: true
             ),
           :ok <- validate_replayed_event_scope(assignment, event) do
        event
      else
        {:ok, event} ->
          return_scoped_replay(repo, assignment, event)

        {:error, reason} ->
          repo.rollback(reason)
      end
    end)
  end

  defp return_scoped_replay(repo, %Assignment{} = assignment, %ProgressEvent{} = event) do
    with :ok <- validate_replay_assignment(repo, assignment),
         :ok <- validate_replayed_event_scope(assignment, event) do
      event
    else
      {:error, reason} -> repo.rollback(reason)
    end
  end

  defp append_progress_event_in_transaction(repo, attrs, changeset_fun, opts) do
    with {:ok, attrs} <- normalize_append_attrs(attrs, Keyword.fetch!(opts, :trusted_audit_metadata)),
         :not_found <-
           existing_progress_event_by_idempotency_key_with_retry(repo, attrs, append_retry_attempts()) do
      repo
      |> insert_with_allocated_value(
        attrs,
        ProgressEvent,
        :sequence,
        changeset_fun
      )
      |> fetch_after_idempotency_conflict(repo, attrs)
      |> clear_work_request_completion_after_reopening_progress(repo)
    end
  end

  defp clear_work_request_completion_after_reopening_progress({:ok, %ProgressEvent{} = event}, repo) do
    if reopening_progress_event?(event) do
      clear_work_request_completion_after_progress(event, repo)
    else
      {:ok, event}
    end
  end

  defp clear_work_request_completion_after_reopening_progress(result, _repo), do: result

  defp clear_work_request_completion_after_progress(%ProgressEvent{work_package_id: work_package_id} = event, repo) do
    case WorkRequestRepository.clear_completion_for_work_package(repo, work_package_id) do
      :ok -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reopening_progress_event?(%ProgressEvent{work_package_id: work_package_id, payload: payload})
       when is_binary(work_package_id) and is_map(payload) do
    WorkRequestCompletion.blocker_event_payload?(payload) and (Map.get(payload, "active") || Map.get(payload, :active)) == true
  end

  defp reopening_progress_event?(%ProgressEvent{}), do: false

  defp normalize_append_attrs(attrs, trusted_audit_metadata?) do
    with :ok <- reject_conflicting_key(attrs, :work_package_id, & &1),
         :ok <- reject_conflicting_key(attrs, :idempotency_key, &String.trim/1),
         :ok <- reject_duplicate_caller_keys(attrs, [:summary, :body, :status, :payload]) do
      attrs = drop_ordering(attrs, :sequence)

      if trusted_audit_metadata? do
        {:ok, attrs}
      else
        {:ok, Map.drop(attrs, [:actor_id, :actor_type, :access_grant_id, :agent_run_id, "actor_id", "actor_type", "access_grant_id", "agent_run_id"])}
      end
    end
  end

  defp reject_conflicting_key(attrs, key, normalize_fun) do
    values =
      [Map.get(attrs, key), Map.get(attrs, Atom.to_string(key))]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn value -> if is_binary(value), do: normalize_fun.(value), else: value end)
      |> Enum.uniq()

    if length(values) > 1, do: {:error, :conflicting_key_forms}, else: :ok
  end

  defp reject_duplicate_caller_keys(attrs, keys) do
    if Enum.any?(keys, &duplicate_key_form?(attrs, &1)) do
      {:error, :conflicting_key_forms}
    else
      :ok
    end
  end

  defp duplicate_key_form?(attrs, key) do
    Map.has_key?(attrs, key) and Map.has_key?(attrs, Atom.to_string(key))
  end

  defp audit_attrs(%Assignment{} = assignment, attrs, opts) do
    attrs = normalize_keys(attrs)
    payload = Map.get(attrs, "payload", %{})

    attrs
    |> Map.take(["summary", "body", "status", "idempotency_key"])
    |> Map.put("work_package_id", assignment.work_package_id)
    |> Map.put("actor_id", assignment.claimed_by)
    |> Map.put("actor_type", assignment.grant_role)
    |> Map.put("access_grant_id", assignment.grant_id)
    |> Map.put("payload", payload)
    |> put_trusted_agent_run_id(Keyword.get(opts, :agent_run_id))
  end

  defp put_trusted_agent_run_id(attrs, agent_run_id) when is_binary(agent_run_id) do
    if String.trim(agent_run_id) == "" do
      attrs
    else
      Map.put(attrs, "agent_run_id", agent_run_id)
    end
  end

  defp put_trusted_agent_run_id(attrs, _agent_run_id), do: attrs

  @spec append_artifact(repo(), map()) :: {:ok, Artifact.t()} | {:error, error()}
  def append_artifact(repo, attrs) when is_atom(repo) and is_map(attrs) do
    insert_with_allocated_value(
      repo,
      drop_ordering(attrs, :sequence),
      Artifact,
      :sequence,
      &Artifact.create_changeset/1
    )
  end

  @spec get_artifact(repo(), String.t()) :: {:ok, Artifact.t() | nil} | {:error, error()}
  def get_artifact(repo, artifact_id) when is_atom(repo) and is_binary(artifact_id) do
    {:ok, repo.get(Artifact, artifact_id)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update_artifact(repo(), Artifact.t(), map()) :: {:ok, Artifact.t()} | {:error, error()}
  def update_artifact(repo, %Artifact{} = artifact, attrs) when is_atom(repo) and is_map(attrs) do
    artifact
    |> Changeset.change(attrs)
    |> update(repo)
  end

  @spec update_plan_node_status(repo(), String.t(), String.t()) :: {:ok, PlanNode.t()} | {:error, error()}
  def update_plan_node_status(repo, plan_node_id, status)
      when is_atom(repo) and is_binary(plan_node_id) and is_binary(status) do
    case repo.get(PlanNode, plan_node_id) do
      nil ->
        {:error, :not_found}

      %PlanNode{} = plan_node ->
        plan_node
        |> PlanNode.status_changeset(%{status: status})
        |> update(repo)
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec update_plan_node(repo(), String.t(), map()) :: {:ok, PlanNode.t()} | {:error, error()}
  def update_plan_node(repo, plan_node_id, attrs)
      when is_atom(repo) and is_binary(plan_node_id) and is_map(attrs) do
    case repo.get(PlanNode, plan_node_id) do
      nil ->
        {:error, :not_found}

      %PlanNode{} = plan_node ->
        plan_node
        |> PlanNode.update_changeset(attrs)
        |> update(repo)
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_plan_nodes(repo(), String.t()) :: {:ok, [PlanNode.t()]} | {:error, error()}
  def list_plan_nodes(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_all(repo, fn ->
      from(plan_node in PlanNode,
        where: plan_node.work_package_id == ^work_package_id,
        order_by: [asc: plan_node.position, asc: plan_node.created_at, asc: plan_node.id]
      )
    end)
  end

  @spec list_findings(repo(), String.t()) :: {:ok, [Finding.t()]} | {:error, error()}
  def list_findings(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_all(repo, fn ->
      from(finding in Finding,
        where: finding.work_package_id == ^work_package_id,
        order_by: [asc: finding.sequence, asc: finding.id]
      )
    end)
  end

  @spec list_progress_events(repo(), String.t()) :: {:ok, [ProgressEvent.t()]} | {:error, error()}
  def list_progress_events(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_all(repo, fn ->
      from(progress_event in ProgressEvent,
        where: progress_event.work_package_id == ^work_package_id,
        order_by: [asc: progress_event.sequence, asc: progress_event.id]
      )
    end)
  end

  @spec get_progress_event_by_idempotency_key(repo(), String.t(), String.t()) ::
          {:ok, ProgressEvent.t()} | {:error, error()}
  def get_progress_event_by_idempotency_key(repo, work_package_id, idempotency_key)
      when is_atom(repo) and is_binary(work_package_id) and is_binary(idempotency_key) do
    get_progress_event_by_idempotency_key(repo, work_package_id, idempotency_key, nil)
  end

  @spec get_progress_event_by_idempotency_key(repo(), String.t(), String.t(), String.t() | nil) ::
          {:ok, ProgressEvent.t()} | {:error, error()}
  def get_progress_event_by_idempotency_key(repo, work_package_id, idempotency_key, nil)
      when is_atom(repo) and is_binary(work_package_id) and is_binary(idempotency_key) do
    safe_one(repo, fn ->
      from(progress_event in ProgressEvent,
        where: progress_event.work_package_id == ^work_package_id,
        where: progress_event.idempotency_key == ^idempotency_key,
        where: progress_event.idempotency_scope == "direct",
        limit: 1
      )
    end)
  end

  def get_progress_event_by_idempotency_key(repo, work_package_id, idempotency_key, access_grant_id)
      when is_atom(repo) and is_binary(work_package_id) and is_binary(idempotency_key) and is_binary(access_grant_id) do
    safe_one(repo, fn ->
      from(progress_event in ProgressEvent,
        where: progress_event.work_package_id == ^work_package_id,
        where: progress_event.idempotency_key == ^idempotency_key,
        where: progress_event.idempotency_scope == ^access_grant_id,
        limit: 1
      )
    end)
  end

  @spec list_artifacts(repo(), String.t()) :: {:ok, [Artifact.t()]} | {:error, error()}
  def list_artifacts(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_all(repo, fn ->
      from(artifact in Artifact,
        where: artifact.work_package_id == ^work_package_id,
        order_by: [asc: artifact.sequence, asc: artifact.id]
      )
    end)
  end

  @spec get_state(repo(), String.t()) :: {:ok, State.t()} | {:error, error()}
  def get_state(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    do_get_state(repo, work_package_id, :full, state_read_retry_attempts())
  end

  @spec get_status_summary(repo(), String.t()) :: {:ok, map()} | {:error, error()}
  def get_status_summary(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    do_get_status_summary(repo, work_package_id, state_read_retry_attempts())
  end

  @spec get_render_state(repo(), String.t()) :: {:ok, State.t()} | {:error, error()}
  def get_render_state(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    do_get_state(repo, work_package_id, :bounded, state_read_retry_attempts())
  end

  @spec get_task_plan_render_state(repo(), String.t()) :: {:ok, State.t()} | {:error, error()}
  def get_task_plan_render_state(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    do_get_state(repo, work_package_id, :task_plan, state_read_retry_attempts())
  end

  defp do_get_status_summary(repo, work_package_id, attempts_left) do
    repo.transaction(fn ->
      with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
           {:ok, plan_nodes} <- list_plan_nodes_version_material(repo, work_package_id) do
        %{
          work_package: work_package,
          plan_nodes: plan_nodes,
          finding_count: count_records(repo, Finding, work_package_id),
          progress_event_count: count_records(repo, ProgressEvent, work_package_id),
          artifact_count: count_records(repo, Artifact, work_package_id)
        }
      else
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> retry_get_status_summary(repo, work_package_id, attempts_left)
  rescue
    error in Exqlite.Error ->
      error
      |> normalize_exqlite_error()
      |> retry_get_status_summary(repo, work_package_id, attempts_left)
  end

  defp retry_get_status_summary({:error, :database_busy}, _repo, _work_package_id, 0), do: {:error, :database_busy}

  defp retry_get_status_summary({:error, :database_busy}, repo, work_package_id, attempts_left) do
    Process.sleep(retry_delay_ms(attempts_left, state_read_retry_attempts()))
    do_get_status_summary(repo, work_package_id, attempts_left - 1)
  end

  defp retry_get_status_summary(result, _repo, _work_package_id, _attempts_left), do: result

  defp do_get_state(repo, work_package_id, mode, attempts_left) do
    repo.transaction(fn ->
      case load_state(repo, work_package_id, mode) do
        {:ok, state} -> state
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> retry_get_state(repo, work_package_id, mode, attempts_left)
  rescue
    error in Exqlite.Error ->
      error
      |> normalize_exqlite_error()
      |> retry_get_state(repo, work_package_id, mode, attempts_left)
  end

  defp retry_get_state({:error, :database_busy}, _repo, _work_package_id, _mode, 0), do: {:error, :database_busy}

  defp retry_get_state({:error, :database_busy}, repo, work_package_id, mode, attempts_left) do
    Process.sleep(retry_delay_ms(attempts_left, state_read_retry_attempts()))
    do_get_state(repo, work_package_id, mode, attempts_left - 1)
  end

  defp retry_get_state(result, _repo, _work_package_id, _mode, _attempts_left), do: result

  defp load_state(repo, work_package_id, :full) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, plan_nodes} <- list_plan_nodes(repo, work_package_id),
         {:ok, findings} <- list_findings(repo, work_package_id),
         {:ok, progress_events} <- list_progress_events(repo, work_package_id),
         {:ok, artifacts} <- list_artifacts(repo, work_package_id) do
      {:ok,
       %State{
         work_package: work_package,
         plan_nodes: plan_nodes,
         findings: findings,
         progress_events: progress_events,
         artifacts: artifacts,
         plan_version_material: plan_nodes,
         plan_nodes_omitted_count: 0,
         findings_omitted_count: 0,
         progress_events_omitted_count: 0,
         artifacts_omitted_count: 0
       }}
    end
  end

  defp load_state(repo, work_package_id, :bounded) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {plan_nodes, plan_nodes_omitted_count} <- list_plan_nodes_for_render(repo, work_package_id),
         {findings, findings_omitted_count} <- list_findings_for_render(repo, work_package_id),
         {progress_events, progress_events_omitted_count} <- list_progress_events_for_render(repo, work_package_id),
         {artifacts, artifacts_omitted_count} <- list_artifacts_for_render(repo, work_package_id) do
      {:ok,
       %State{
         work_package: work_package,
         plan_nodes: plan_nodes,
         findings: findings,
         progress_events: progress_events,
         artifacts: artifacts,
         plan_nodes_omitted_count: plan_nodes_omitted_count,
         findings_omitted_count: findings_omitted_count,
         progress_events_omitted_count: progress_events_omitted_count,
         artifacts_omitted_count: artifacts_omitted_count
       }}
    end
  end

  defp load_state(repo, work_package_id, :task_plan) do
    with {:ok, %State{} = state} <- load_state(repo, work_package_id, :bounded),
         {:ok, plan_version_material} <- list_plan_nodes_version_material(repo, work_package_id) do
      {:ok, %State{state | plan_version_material: plan_version_material}}
    end
  end

  defp list_plan_nodes_for_render(repo, work_package_id) do
    rows =
      repo.all(
        from(plan_node in PlanNode,
          where: plan_node.work_package_id == ^work_package_id,
          order_by: [asc: plan_node.position, asc: plan_node.created_at, asc: plan_node.id],
          limit: @state_item_limit
        )
      )

    {rows, omitted_count(repo, PlanNode, work_package_id, rows)}
  end

  defp list_plan_nodes_version_material(repo, work_package_id) do
    rows =
      repo.all(
        from(plan_node in PlanNode,
          where: plan_node.work_package_id == ^work_package_id,
          order_by: [asc: plan_node.position, asc: plan_node.created_at, asc: plan_node.id],
          select: %{
            id: plan_node.id,
            title: plan_node.title,
            body: plan_node.body,
            status: plan_node.status,
            position: plan_node.position,
            updated_at: plan_node.updated_at
          }
        )
      )

    {:ok, rows}
  end

  defp list_findings_for_render(repo, work_package_id) do
    rows =
      repo.all(
        from(finding in Finding,
          where: finding.work_package_id == ^work_package_id,
          order_by: [desc: finding.sequence, desc: finding.id],
          limit: @state_item_limit
        )
      )
      |> Enum.reverse()

    {rows, omitted_count(repo, Finding, work_package_id, rows)}
  end

  defp list_progress_events_for_render(repo, work_package_id) do
    rows =
      repo.all(
        from(progress_event in ProgressEvent,
          where: progress_event.work_package_id == ^work_package_id,
          order_by: [desc: progress_event.sequence, desc: progress_event.id],
          limit: @state_item_limit
        )
      )
      |> Enum.reverse()

    {rows, omitted_count(repo, ProgressEvent, work_package_id, rows)}
  end

  defp list_artifacts_for_render(repo, work_package_id) do
    rows =
      repo.all(
        from(artifact in Artifact,
          where: artifact.work_package_id == ^work_package_id,
          order_by: [desc: artifact.sequence, desc: artifact.id],
          limit: @state_item_limit
        )
      )
      |> Enum.reverse()

    {rows, omitted_count(repo, Artifact, work_package_id, rows)}
  end

  defp safe_all(repo, query_fun) do
    {:ok, repo.all(query_fun.())}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp safe_one(repo, query_fun) do
    case repo.one(query_fun.()) do
      nil -> {:error, :not_found}
      row -> {:ok, row}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp existing_progress_event_by_idempotency_key(repo, attrs) do
    with work_package_id when is_binary(work_package_id) <- attr(attrs, :work_package_id),
         idempotency_key when is_binary(idempotency_key) <- attr(attrs, :idempotency_key),
         access_grant_id <- attr(attrs, :access_grant_id),
         idempotency_key <- String.trim(idempotency_key),
         false <- idempotency_key == "",
         {:ok, progress_event} <-
           get_progress_event_by_idempotency_key(repo, work_package_id, idempotency_key, access_grant_id) do
      {:ok, progress_event}
    else
      {:error, :not_found} -> :not_found
      {:error, reason} -> {:error, reason}
      _value -> :not_found
    end
  end

  defp existing_progress_event_by_idempotency_key_with_retry(repo, attrs, attempts_left) do
    case existing_progress_event_by_idempotency_key(repo, attrs) do
      {:error, :database_busy} when attempts_left > 0 ->
        Process.sleep(retry_delay_ms(attempts_left, append_retry_attempts()))
        existing_progress_event_by_idempotency_key_with_retry(repo, attrs, attempts_left - 1)

      result ->
        result
    end
  end

  defp fetch_after_idempotency_conflict({:error, :idempotency_key_conflict}, repo, attrs) do
    with work_package_id when is_binary(work_package_id) <- attr(attrs, :work_package_id),
         idempotency_key when is_binary(idempotency_key) <- attr(attrs, :idempotency_key),
         access_grant_id <- attr(attrs, :access_grant_id),
         idempotency_key <- String.trim(idempotency_key) do
      get_progress_event_by_idempotency_key_with_retry(
        repo,
        work_package_id,
        idempotency_key,
        access_grant_id,
        append_retry_attempts()
      )
    else
      _value -> {:error, :idempotency_key_conflict}
    end
  end

  defp fetch_after_idempotency_conflict(result, _repo, _attrs), do: result

  defp get_progress_event_by_idempotency_key_with_retry(
         repo,
         work_package_id,
         idempotency_key,
         access_grant_id,
         attempts_left
       ) do
    case get_progress_event_by_idempotency_key(repo, work_package_id, idempotency_key, access_grant_id) do
      {:error, :database_busy} when attempts_left > 0 ->
        Process.sleep(retry_delay_ms(attempts_left, append_retry_attempts()))

        get_progress_event_by_idempotency_key_with_retry(
          repo,
          work_package_id,
          idempotency_key,
          access_grant_id,
          attempts_left - 1
        )

      result ->
        result
    end
  end

  defp lock_valid_assignment(repo, %Assignment{} = assignment) do
    if is_nil(assignment.claimed_at) or is_nil(assignment.claimed_by) do
      {:error, :assignment_mismatch}
    else
      case repo.update_all(valid_assignment_query(assignment), set: [claimed_by: assignment.claimed_by]) do
        {1, _rows} -> :ok
        {0, _rows} -> assignment_error(repo, assignment.grant_id)
      end
    end
  end

  defp valid_assignment_query(%Assignment{} = assignment) do
    now = DateTime.utc_now(:microsecond)

    from(grant in AccessGrant,
      where: grant.id == ^assignment.grant_id,
      where: grant.work_package_id == ^assignment.work_package_id,
      where: grant.display_key == ^assignment.display_key,
      where: grant.grant_role == ^assignment.grant_role,
      where: grant.capabilities == ^assignment.capabilities,
      where: grant.claimed_at == ^assignment.claimed_at,
      where: grant.claimed_by == ^assignment.claimed_by,
      where: not is_nil(grant.claimed_at),
      where: not is_nil(grant.claimed_by),
      where: is_nil(grant.revoked_at),
      where: is_nil(grant.expires_at) or grant.expires_at > ^now
    )
  end

  defp validate_replay_assignment(repo, %Assignment{} = assignment) do
    if is_nil(assignment.claimed_at) or is_nil(assignment.claimed_by) do
      {:error, :assignment_mismatch}
    else
      case repo.one(matching_assignment_query(assignment)) do
        %AccessGrant{} -> :ok
        nil -> assignment_error(repo, assignment.grant_id)
      end
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp matching_assignment_query(%Assignment{} = assignment) do
    now = DateTime.utc_now(:microsecond)

    from(grant in AccessGrant,
      where: grant.id == ^assignment.grant_id,
      where: grant.work_package_id == ^assignment.work_package_id,
      where: grant.display_key == ^assignment.display_key,
      where: grant.grant_role == ^assignment.grant_role,
      where: grant.capabilities == ^assignment.capabilities,
      where: grant.claimed_at == ^assignment.claimed_at,
      where: grant.claimed_by == ^assignment.claimed_by,
      where: not is_nil(grant.claimed_at),
      where: not is_nil(grant.claimed_by),
      where: is_nil(grant.revoked_at),
      where: is_nil(grant.expires_at) or grant.expires_at > ^now,
      limit: 1
    )
  end

  defp assignment_error(repo, grant_id) do
    case repo.get(AccessGrant, grant_id) do
      %AccessGrant{revoked_at: %DateTime{}} -> {:error, :assignment_revoked}
      %AccessGrant{expires_at: %DateTime{} = expires_at} -> expired_assignment_error(expires_at)
      _grant -> {:error, :assignment_mismatch}
    end
  end

  defp expired_assignment_error(%DateTime{} = expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) == :gt do
      {:error, :assignment_mismatch}
    else
      {:error, :expired}
    end
  end

  defp validate_replayed_event_scope(%Assignment{} = assignment, %ProgressEvent{} = event) do
    if event.access_grant_id == assignment.grant_id and event.actor_id == assignment.claimed_by and
         event.actor_type == assignment.grant_role do
      :ok
    else
      {:error, :idempotency_scope_conflict}
    end
  end

  defp omitted_count(repo, schema, work_package_id, loaded_rows) do
    total = count_records(repo, schema, work_package_id)

    max(total - length(loaded_rows), 0)
  end

  defp count_records(repo, schema, work_package_id) do
    repo.one(
      from(row in schema,
        where: row.work_package_id == ^work_package_id,
        select: count(row.id)
      )
    ) || 0
  end

  defp insert_with_allocated_value(repo, attrs, schema, field, changeset_fun) do
    normalized_attrs = normalize_keys(attrs)
    string_field = Atom.to_string(field)
    auto_allocate? = Map.get(normalized_attrs, string_field) in [nil, ""]

    do_insert_with_allocated_value(
      repo,
      normalized_attrs,
      schema,
      field,
      changeset_fun,
      auto_allocate?,
      append_retry_attempts()
    )
  end

  defp do_insert_with_allocated_value(repo, attrs, schema, field, changeset_fun, auto_allocate?, attempts_left) do
    repo
    |> insert_transaction(attrs, schema, field, changeset_fun, auto_allocate?)
    |> handle_insert_result(repo, attrs, schema, field, changeset_fun, auto_allocate?, attempts_left)
  end

  defp insert_transaction(repo, attrs, schema, field, changeset_fun, auto_allocate?) do
    repo.transaction(fn ->
      attrs
      |> maybe_put_next_value(repo, schema, field, auto_allocate?)
      |> changeset_fun.()
      |> insert(repo)
      |> case do
        {:ok, row} -> row
        {:error, reason} -> repo.rollback(reason)
      end
    end)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp handle_insert_result({:ok, row}, _repo, _attrs, _schema, _field, _changeset_fun, _auto_allocate?, _attempts_left) do
    {:ok, row}
  end

  defp handle_insert_result(
         {:error, {:constraint_failed, constraint}},
         repo,
         attrs,
         schema,
         field,
         changeset_fun,
         true,
         attempts_left
       ) do
    if append_order_constraint?(constraint) do
      retry_or_error(repo, attrs, schema, field, changeset_fun, attempts_left, :sequence_conflict)
    else
      {:error, {:constraint_failed, constraint}}
    end
  end

  defp handle_insert_result({:error, :database_busy}, repo, attrs, schema, field, changeset_fun, true, attempts_left) do
    retry_or_error(repo, attrs, schema, field, changeset_fun, attempts_left, :database_busy)
  end

  defp handle_insert_result({:error, reason}, _repo, _attrs, _schema, _field, _changeset_fun, _auto_allocate?, _attempts_left) do
    {:error, reason}
  end

  defp retry_or_error(_repo, _attrs, _schema, _field, _changeset_fun, 0, terminal_error), do: {:error, terminal_error}

  defp retry_or_error(repo, attrs, schema, field, changeset_fun, attempts_left, _terminal_error) do
    Process.sleep(retry_delay_ms(attempts_left, append_retry_attempts()))
    do_insert_with_allocated_value(repo, attrs, schema, field, changeset_fun, true, attempts_left - 1)
  end

  defp retry_delay_ms(attempts_left, total_attempts) do
    used_attempts = max(total_attempts - attempts_left, 0)
    min(100, 5 + used_attempts * 5)
  end

  defp append_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_planning_append_retry_attempts, @default_append_retry_attempts)
    |> max(0)
  end

  defp state_read_retry_attempts do
    :symphony_elixir
    |> Application.get_env(:sympp_planning_state_read_retry_attempts, @default_state_read_retry_attempts)
    |> max(0)
  end

  defp maybe_put_next_value(attrs, repo, schema, field, true) do
    if is_binary(Map.get(attrs, "work_package_id")) do
      Map.put(attrs, Atom.to_string(field), next_value(repo, schema, field, Map.fetch!(attrs, "work_package_id")))
    else
      attrs
    end
  end

  defp maybe_put_next_value(attrs, _repo, _schema, _field, false) do
    attrs
  end

  defp next_value(repo, schema, field, work_package_id) do
    current_max =
      repo.one(
        from(row in schema,
          where: row.work_package_id == ^work_package_id,
          select: max(field(row, ^field))
        )
      )

    (current_max || 0) + 1
  end

  defp insert(changeset, repo) do
    changeset
    |> repo.insert()
    |> normalize_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp update(changeset, repo) do
    changeset
    |> repo.update()
    |> normalize_update_result()
  rescue
    _error in Ecto.StaleEntryError -> {:error, :not_found}
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp normalize_update_result({:ok, row}), do: {:ok, row}
  defp normalize_update_result({:error, %Changeset{} = changeset}), do: {:error, changeset}

  defp normalize_insert_result({:ok, row}), do: {:ok, row}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    cond do
      duplicate_id?(changeset) -> {:error, :id_already_exists}
      duplicate_idempotency_key?(changeset) -> {:error, :idempotency_key_conflict}
      true -> {:error, changeset}
    end
  end

  defp duplicate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:id, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp duplicate_idempotency_key?(changeset) do
    Enum.any?(changeset.errors, fn
      {:idempotency_key, {_message, options}} -> Keyword.get(options, :constraint) == :unique
      _error -> false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    if idempotency_constraint?(constraint) do
      {:error, :idempotency_key_conflict}
    else
      if String.ends_with?(constraint, "_id_unique_index") or String.ends_with?(constraint, "_id_index") or
           String.ends_with?(constraint, "_pkey") do
        {:error, :id_already_exists}
      else
        {:error, {:constraint_failed, constraint}}
      end
    end
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp append_order_constraint?(constraint) when is_binary(constraint) do
    String.contains?(constraint, "_work_package_position_unique_index") or
      String.contains?(constraint, "_work_package_sequence_unique_index") or
      sqlite_append_order_constraint?(constraint)
  end

  defp sqlite_append_order_constraint?(constraint) do
    (String.contains?(constraint, "UNIQUE constraint failed:") and
       (String.contains?(constraint, ".sequence") or String.contains?(constraint, ".position"))) or
      (String.contains?(constraint, "work_package") and
         (String.contains?(constraint, "sequence") or String.contains?(constraint, "position")))
  end

  defp idempotency_constraint?(constraint) when is_binary(constraint) do
    constraint == "sympp_progress_events_work_package_idempotency_key_unique_index" or
      (String.contains?(constraint, "sympp_progress_events") and String.contains?(constraint, "idempotency_key")) or
      constraint == "sympp_findings_scoped_idempotency_key_unique_index" or
      (String.contains?(constraint, "sympp_findings") and String.contains?(constraint, "idempotency_key"))
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    if String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp drop_ordering(attrs, field) do
    attrs
    |> normalize_keys()
    |> Map.drop([Atom.to_string(field)])
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp attr(attrs, key) when is_atom(key) do
    Map.get(attrs, Atom.to_string(key)) || Map.get(attrs, key)
  end
end
