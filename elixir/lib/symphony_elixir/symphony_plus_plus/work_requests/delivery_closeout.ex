defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryCloseout do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Repository, as: ClaimLeaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorktreeCleanupQueue
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.RuntimeCleanup
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @abandonable_no_code_statuses ["planning", "ready_for_worker"]
  @abandoned_no_code_status "abandoned"
  @work_package_delivery_replay_fields [
    :work_request_id,
    :work_package_id,
    :outcome,
    :idempotency_key,
    :recorded_by,
    :pr_url,
    :pr_number,
    :pr_repository,
    :pr_merged_at,
    :merge_commit_sha,
    :no_pr_evidence,
    :successor_work_package_id,
    :superseded_reason,
    :abandoned_rationale
  ]
  @type error ::
          Repository.error()
          | WorkPackageRepository.error()
          | ClaimLeaseRepository.error()
          | PlanningRepository.error()
          | :active_blocker
          | :active_runtime
          | :claim_not_current
          | :idempotency_key_conflict
          | :malformed_pr_evidence
          | :missing_strong_pr_evidence
          | :work_package_not_abandonable

  @spec record(Repository.repo(), String.t(), String.t(), map()) ::
          {:ok, WorkPackageDelivery.t()} | {:error, error()}
  def record(repo, work_request_id, work_package_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(work_package_id) and
             is_map(attrs) do
    with {:ok, {delivery, work_package, closeout_context}} <-
           commit_record(repo, work_request_id, work_package_id, attrs) do
      cleanup_after_commit(repo, work_package, delivery, closeout_context)
      {:ok, delivery}
    end
  end

  defp commit_record(repo, work_request_id, work_package_id, attrs) do
    repo.transaction(fn ->
      repo
      |> record_in_transaction(work_request_id, work_package_id, attrs)
      |> rollback_record_result(repo)
    end)
    |> normalize_transaction_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @doc false
  @spec record_in_transaction(Repository.repo(), String.t(), String.t(), map()) ::
          {:ok, {WorkPackageDelivery.t(), WorkPackage.t(), map()}} | {:error, error()}
  def record_in_transaction(repo, work_request_id, work_package_id, attrs)
      when is_atom(repo) and is_binary(work_request_id) and is_binary(work_package_id) and
             is_map(attrs) do
    with {:ok, work_package} <-
           Repository.get_work_package(repo, work_request_id, work_package_id),
         {:ok, delivery} <- validate_delivery_input(work_request_id, work_package_id, attrs),
         :ok <-
           validate_pre_cleanup_closeout(
             repo,
             work_package,
             delivery,
             delivery_closeout_opts(attrs)
           ),
         {:ok, work_request} <- Repository.get(repo, work_request_id),
         {:ok, delivery} <-
           Repository.record_work_package_delivery_in_transaction(
             repo,
             work_request_id,
             work_package_id,
             attrs
           ),
         closeout_opts = delivery_closeout_opts(attrs),
         {:ok, {delivery, closeout_context}} <-
           complete_closeout(repo, work_request, work_package, delivery, closeout_opts) do
      {:ok, {delivery, work_package, closeout_context}}
    end
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @doc false
  @spec cleanup_after_commit(Repository.repo(), WorkPackage.t(), WorkPackageDelivery.t(), map()) :: :ok
  def cleanup_after_commit(_repo, %WorkPackage{}, %WorkPackageDelivery{}, _closeout_context),
    do: WorktreeCleanupQueue.wake()

  defp rollback_record_result({:ok, result}, _repo), do: result
  defp rollback_record_result({:error, reason}, repo), do: repo.rollback(reason)

  defp validate_delivery_input(work_request_id, work_package_id, attrs) do
    attrs =
      attrs
      |> Map.drop([
        "id",
        :id,
        "inserted_at",
        :inserted_at,
        "recorded_at",
        :recorded_at,
        "updated_at",
        :updated_at
      ])
      |> Map.put("work_request_id", work_request_id)
      |> Map.put("work_package_id", work_package_id)

    WorkPackageDelivery.create_changeset(attrs)
    |> Ecto.Changeset.apply_action(:insert)
  end

  defp validate_pre_cleanup_closeout(
         repo,
         %WorkPackage{} = work_package,
         %WorkPackageDelivery{} = delivery,
         opts
       ) do
    case existing_delivery_state(repo, work_package, delivery) do
      :replayed_closeout ->
        :ok

      :new_or_unclosed_replay ->
        validate_new_closeout_pre_cleanup(repo, work_package, delivery, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_new_closeout_pre_cleanup(
         repo,
         %WorkPackage{} = work_package,
         %WorkPackageDelivery{} = delivery,
         opts
       ) do
    with :ok <- validate_delivery_scope(repo, work_package, delivery),
         :ok <- validate_closeout_progress_slot(repo, work_package, delivery),
         :ok <- validate_terminal_evidence(work_package, delivery) do
      validate_linked_closeout_preconditions(repo, work_package, delivery, opts)
    end
  end

  defp validate_delivery_scope(
         repo,
         %WorkPackage{work_request_id: work_request_id},
         %WorkPackageDelivery{outcome: "superseded"} = delivery
       ) do
    case repo.get(WorkPackage, delivery.successor_work_package_id) do
      %WorkPackage{work_request_id: ^work_request_id} -> :ok
      _result -> {:error, :not_found}
    end
  end

  defp validate_delivery_scope(_repo, %WorkPackage{}, %WorkPackageDelivery{}), do: :ok

  defp validate_closeout_progress_slot(
         repo,
         %WorkPackage{id: work_package_id} = work_package,
         %WorkPackageDelivery{} = delivery
       ) do
    with true <- filled_string?(work_package_id),
         {:ok, event} <-
           PlanningRepository.get_progress_event_by_idempotency_key(
             repo,
             work_package_id,
             closeout_idempotency_key(delivery)
           ) do
      if closeout_progress_slot_matches?(event, work_package, delivery) do
        :ok
      else
        {:error, :idempotency_key_conflict}
      end
    else
      false -> :ok
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp closeout_progress_slot_matches?(
         event,
         %WorkPackage{} = work_package,
         %WorkPackageDelivery{} = delivery
       ) do
    closeout_progress_event_matches?(
      event,
      work_package,
      delivery,
      terminal_status_for_outcome(delivery.outcome)
    )
  end

  defp existing_delivery_state(
         repo,
         %WorkPackage{} = work_package,
         %WorkPackageDelivery{} = delivery
       ) do
    case existing_work_package_delivery(repo, delivery.work_package_id) do
      nil ->
        :new_or_unclosed_replay

      %WorkPackageDelivery{} = existing ->
        cond do
          not work_package_delivery_replay?(existing, delivery) ->
            {:error, :delivery_outcome_conflict}

          closeout_progress_replay?(repo, work_package, existing) ->
            :replayed_closeout

          true ->
            :new_or_unclosed_replay
        end
    end
  end

  defp existing_work_package_delivery(repo, work_package_id) do
    repo.one(
      from(delivery in WorkPackageDelivery,
        where: delivery.work_package_id == ^work_package_id,
        limit: 1
      )
    )
  end

  defp work_package_delivery_replay?(
         %WorkPackageDelivery{} = existing,
         %WorkPackageDelivery{} = candidate
       ) do
    Enum.all?(@work_package_delivery_replay_fields, fn field ->
      Map.get(existing, field) == Map.get(candidate, field)
    end)
  end

  defp validate_linked_closeout_preconditions(
         repo,
         %WorkPackage{id: work_package_id},
         %WorkPackageDelivery{} = delivery,
         opts
       ) do
    case filled_string?(work_package_id) do
      true ->
        validate_work_package_closeout_preconditions(repo, work_package_id, delivery, opts)

      false ->
        :ok
    end
  end

  defp validate_work_package_closeout_preconditions(
         repo,
         work_package_id,
         %WorkPackageDelivery{} = delivery,
         opts
       ) do
    context = WorkPackageActivity.context(repo, work_package_id)

    validate_closeout_context(repo, work_package_id, delivery, context, opts)
  end

  defp validate_closeout_context(repo, work_package_id, delivery, context, opts) do
    with :ok <- maybe_reject_active_blocker_context(context, allow_active_blockers?(delivery, opts)) do
      maybe_require_abandonable_package(repo, work_package_id, delivery, context)
    end
  end

  defp allow_active_blockers?(%WorkPackageDelivery{outcome: outcome}, _opts)
       when outcome in ["superseded", "abandoned"],
       do: true

  defp allow_active_blockers?(%WorkPackageDelivery{}, opts),
    do: Keyword.get(opts, :allow_active_blockers?, false)

  defp maybe_require_abandonable_package(
         repo,
         work_package_id,
         %WorkPackageDelivery{outcome: "abandoned"},
         context
       ) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
      require_abandonable_no_code_status(repo, work_package, context)
    end
  end

  defp maybe_require_abandonable_package(_repo, _work_package_id, %WorkPackageDelivery{}, _context), do: :ok

  defp validate_terminal_evidence(
         %WorkPackage{id: work_package_id},
         %WorkPackageDelivery{outcome: "pr_merged"} = delivery
       ) do
    cond do
      not merged_pr_fields?(delivery) ->
        {:error, :missing_strong_pr_evidence}

      filled_string?(work_package_id) and not filled_string?(delivery.merge_commit_sha) ->
        {:error, :missing_strong_pr_evidence}

      not well_formed_pr_evidence?(delivery) ->
        {:error, :malformed_pr_evidence}

      true ->
        :ok
    end
  end

  defp validate_terminal_evidence(%WorkPackage{}, %WorkPackageDelivery{}), do: :ok

  defp complete_closeout(
         repo,
         %WorkRequest{} = work_request,
         %WorkPackage{} = work_package,
         %WorkPackageDelivery{} = delivery,
         opts
       ) do
    case closeout_progress_replay?(repo, work_package, delivery) do
      true ->
        refresh_replayed_closeout(repo, work_request, delivery)

      false ->
        perform_closeout(repo, work_request, work_package, delivery, opts)
    end
  end

  defp refresh_replayed_closeout(
         repo,
         %WorkRequest{} = work_request,
         %WorkPackageDelivery{} = delivery
       ) do
    context = WorkPackageActivity.context(repo, delivery.work_package_id)

    with {:ok, event} <-
           PlanningRepository.get_progress_event_by_idempotency_key(
             repo,
             delivery.work_package_id,
             closeout_idempotency_key(delivery)
           ),
         {:ok, _refreshed} <- Completion.refresh_in_transaction(repo, work_request.id) do
      {:ok, {delivery, replay_closeout_context(context, event)}}
    end
  end

  defp replay_closeout_context(context, event) do
    current = closeout_context(context, [], [], allow_active_blockers?: false)
    recorded_reasons = List.wrap(map_value(event.payload, :runtime_reason_codes_before_closeout))

    current
    |> Map.update!(:runtime_reason_codes, &Enum.uniq(recorded_reasons ++ &1))
    |> Map.put(:defer_worktree_cleanup?, current.defer_worktree_cleanup?)
  end

  defp perform_closeout(
         repo,
         %WorkRequest{} = work_request,
         %WorkPackage{} = work_package,
         %WorkPackageDelivery{} = delivery,
         opts
       ) do
    with {:ok, closeout_context} <-
           prepare_linked_closeout_context(repo, work_package, delivery, opts),
         {:ok, closeout} <-
           close_work_package(
             repo,
             work_request,
             work_package,
             delivery,
             closeout_context
           ),
         {:ok, _event} <-
           append_closeout_progress(
             repo,
             work_request,
             work_package,
             delivery,
             closeout,
             closeout_context
           ),
         {:ok, _refreshed} <- Completion.refresh_in_transaction(repo, work_request.id) do
      {:ok, {delivery, closeout_context}}
    end
  end

  defp close_work_package(
         repo,
         %WorkRequest{} = work_request,
         %WorkPackage{} = work_package,
         %WorkPackageDelivery{} = delivery,
         closeout_context
       ) do
    WorkPackageRepository.close_delivery_work_package(
      repo,
      work_request,
      work_package,
      terminal_status_for_outcome(delivery.outcome),
      allow_active_blockers?: Map.get(closeout_context, :allow_active_blockers?, false),
      allow_active_runtime?: true
    )
  end

  defp append_closeout_progress(
         repo,
         %WorkRequest{} = work_request,
         %WorkPackage{} = work_package,
         %WorkPackageDelivery{} = delivery,
         closeout,
         closeout_context
       )
       when is_map(closeout) do
    with {:ok, event} <-
           PlanningRepository.append_progress_event(repo, %{
             work_package_id: closeout.work_package.id,
             summary: closeout_progress_summary(delivery, closeout_context),
             status: closeout.next_status,
             idempotency_key: closeout_idempotency_key(delivery),
             payload:
               closeout_progress_payload(
                 work_request,
                 work_package,
                 delivery,
                 closeout,
                 closeout_context
               )
           }),
         true <-
           closeout_progress_event_matches?(event, work_package, delivery, closeout.next_status) do
      {:ok, event}
    else
      false -> {:error, :idempotency_key_conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp terminal_status_for_outcome(outcome),
    do: WorkPackageDelivery.terminal_status_for_outcome(outcome)

  defp prepare_linked_closeout_context(
         repo,
         %WorkPackage{id: work_package_id},
         %WorkPackageDelivery{} = delivery,
         opts
       ) do
    case filled_string?(work_package_id) do
      true -> prepare_work_package_closeout_context(repo, work_package_id, delivery, opts)
      false -> {:ok, empty_closeout_context()}
    end
  end

  defp prepare_work_package_closeout_context(
         repo,
         work_package_id,
         %WorkPackageDelivery{} = delivery,
         opts
       ) do
    context = WorkPackageActivity.context(repo, work_package_id)
    allow_active_blockers? = allow_active_blockers?(delivery, opts)

    with :ok <- validate_closeout_context(repo, work_package_id, delivery, context, opts),
         {:ok, retired_worker_grant_ids} <- retire_live_worker_grants(repo, work_package_id),
         {:ok, retired_claim_lease_ids} <-
           retire_current_claim_leases(repo, work_package_id, "#{delivery.outcome}_delivery_closeout") do
      {:ok,
       closeout_context(
         context,
         retired_worker_grant_ids,
         retired_claim_lease_ids,
         allow_active_blockers?: allow_active_blockers?
       )}
    end
  end

  defp maybe_reject_active_blocker_context(_context, true), do: :ok

  defp maybe_reject_active_blocker_context(context, false) do
    if get_in(context, [:blocker_state, :active?]) == true do
      {:error, :active_blocker}
    else
      :ok
    end
  end

  defp delivery_closeout_opts(_attrs), do: [allow_active_blockers?: true]

  defp require_abandonable_no_code_status(_repo, %{status: status}, _context)
       when status in @abandonable_no_code_statuses, do: :ok

  defp require_abandonable_no_code_status(
         repo,
         %{id: work_package_id, status: @abandoned_no_code_status},
         context
       ) do
    with {:ok, events} <- PlanningRepository.list_progress_events(repo, work_package_id) do
      cond do
        recycled_runtime_context?(context) and
            Enum.any?(events, &abandoned_runtime_cleanup_event?/1) ->
          :ok

        not Enum.any?(events, &abandoned_progress_event?/1) ->
          {:error, :active_runtime}

        true ->
          :ok
      end
    end
  end

  defp require_abandonable_no_code_status(_repo, _work_package, _context),
    do: {:error, :work_package_not_abandonable}

  defp recycled_runtime_context?(context),
    do: get_in(context, [:runtime_state, :recycled?]) == true

  defp abandoned_runtime_cleanup_event?(%{payload: payload}) when is_map(payload) do
    map_value(payload, :source_tool) == RuntimeCleanup.source_tool() and
      get_in(payload, ["delivery_evidence", "outcome"]) == @abandoned_no_code_status
  end

  defp abandoned_runtime_cleanup_event?(_event), do: false

  defp abandoned_progress_event?(%{status: @abandoned_no_code_status}), do: true

  defp abandoned_progress_event?(%{payload: payload}) when is_map(payload) do
    map_value(payload, :status) == @abandoned_no_code_status or
      map_value(payload, :next_status) == @abandoned_no_code_status
  end

  defp abandoned_progress_event?(_event), do: false

  defp empty_closeout_context do
    closeout_context(WorkPackageActivity.empty_context(), [], [], allow_active_blockers?: false)
  end

  defp closeout_context(context, retired_worker_grant_ids, retired_claim_lease_ids, opts) do
    runtime_reason_codes = List.wrap(get_in(context, [:runtime_state, :reason_codes]))

    %{
      active_blocker_ids: List.wrap(get_in(context, [:blocker_state, :active_ids])),
      blocker_reason_codes: List.wrap(get_in(context, [:blocker_state, :reason_codes])),
      runtime_reason_codes: runtime_reason_codes,
      ignored_stale_agent_run_ids: List.wrap(get_in(context, [:runtime_state, :stale_agent_run_ids])),
      retired_worker_grant_ids: retired_worker_grant_ids,
      retired_claim_lease_ids: retired_claim_lease_ids,
      defer_worktree_cleanup?: Enum.any?(runtime_reason_codes, &live_runtime_reason?/1),
      allow_active_blockers?: Keyword.get(opts, :allow_active_blockers?, false)
    }
  end

  defp live_runtime_reason?(reason),
    do:
      reason in [
        "claim_lease_paused",
        "claim_lease_active",
        "agent_run_active",
        "worker_grant_active",
        "architect_grant_active"
      ]

  defp retire_current_claim_leases(repo, work_package_id, reason) do
    case ClaimLeaseRepository.retire_current_for_work_package(
           repo,
           work_package_id,
           reason
         ) do
      {:ok, claim_leases} -> {:ok, Enum.map(claim_leases, & &1.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retire_live_worker_grants(repo, work_package_id) do
    revoke_worker_grants(
      live_worker_grants(repo, work_package_id, DateTime.utc_now(:microsecond)),
      repo
    )
  end

  defp revoke_worker_grants(grants, repo) do
    now = DateTime.utc_now(:microsecond)

    grants
    |> Enum.reduce_while({:ok, []}, fn %AccessGrant{} = grant, {:ok, grant_ids} ->
      case grant |> AccessGrant.revoke_changeset(now) |> repo.update() do
        {:ok, %AccessGrant{} = revoked_grant} -> {:cont, {:ok, [revoked_grant.id | grant_ids]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, grant_ids} -> {:ok, Enum.reverse(grant_ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp live_worker_grants(repo, work_package_id, %DateTime{} = now) do
    repo.all(
      from(grant in AccessGrant,
        where: grant.work_package_id == ^work_package_id,
        where: grant.grant_role == "worker",
        where: is_nil(grant.revoked_at),
        where: is_nil(grant.expires_at) or grant.expires_at > ^now,
        order_by: [asc: grant.inserted_at, asc: grant.id]
      )
    )
  end

  defp closeout_progress_replay?(
         repo,
         %WorkPackage{id: work_package_id},
         %WorkPackageDelivery{} = delivery
       ) do
    with true <- filled_string?(work_package_id),
         {:ok, event} <-
           PlanningRepository.get_progress_event_by_idempotency_key(
             repo,
             work_package_id,
             closeout_idempotency_key(delivery)
           ),
         {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         true <-
           WorkPackageDelivery.terminal_status_matches_outcome?(
             work_package.status,
             delivery.outcome
           ),
         true <- closeout_progress_event_matches?(event, delivery, work_package.status) do
      true
    else
      _result -> false
    end
  end

  defp closeout_progress_event_matches?(
         event,
         %WorkPackage{id: work_package_id},
         %WorkPackageDelivery{} = delivery,
         next_status
       ) do
    event.work_package_id == work_package_id and
      closeout_progress_event_matches?(event, delivery, next_status)
  end

  defp closeout_progress_event_matches?(event, %WorkPackageDelivery{} = delivery, next_status) do
    event.idempotency_key == closeout_idempotency_key(delivery) and
      event.status == next_status and
      closeout_progress_payload_matches?(event.payload || %{}, delivery, next_status)
  end

  defp closeout_progress_payload_matches?(
         payload,
         %WorkPackageDelivery{} = delivery,
         next_status
       ) do
    closeout_progress_payload_identity_matches?(payload, delivery) and
      map_value(payload, :next_status) == next_status
  end

  defp closeout_progress_payload_identity_matches?(payload, %WorkPackageDelivery{} = delivery) do
    map_value(payload, :type) == "work_request_delivery_closeout" and
      map_value(payload, :source_tool) == "record_work_package_delivery" and
      map_value(payload, :work_request_id) == delivery.work_request_id and
      map_value(payload, :work_package_id) == delivery.work_package_id and
      map_value(payload, :delivery_id) == delivery.id and
      map_value(payload, :outcome) == delivery.outcome
  end

  defp merged_pr_fields?(%WorkPackageDelivery{} = delivery) do
    filled_string?(delivery.pr_url) and
      match?(%DateTime{}, delivery.pr_merged_at)
  end

  defp well_formed_pr_evidence?(%WorkPackageDelivery{} = delivery) do
    case github_pr_url_parts(delivery.pr_url) do
      {:ok, parts} ->
        pr_repository_matches?(delivery.pr_repository, parts.repository) and
          pr_number_matches?(delivery.pr_number, parts.number)

      :not_github ->
        valid_absolute_url?(delivery.pr_url)

      :error ->
        false
    end
  end

  defp github_pr_url_parts(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    cond do
      not valid_absolute_url?(uri) ->
        :error

      String.downcase(uri.host || "") not in ["github.com", "www.github.com"] ->
        :not_github

      true ->
        github_pr_path_parts(uri.path)
    end
  end

  defp github_pr_url_parts(_url), do: :error

  defp github_pr_path_parts(path) do
    case path |> to_string() |> String.split("/", trim: true) do
      [owner, repo, "pull", number | _rest] -> github_pr_number_parts(owner, repo, number)
      _invalid_path -> :error
    end
  end

  defp github_pr_number_parts(owner, repo, number) do
    case Integer.parse(number) do
      {number, ""} when number > 0 -> {:ok, %{repository: "#{owner}/#{repo}", number: number}}
      _invalid_number -> :error
    end
  end

  defp valid_absolute_url?(url) when is_binary(url) do
    url |> String.trim() |> URI.parse() |> valid_absolute_url?()
  end

  defp valid_absolute_url?(%URI{scheme: scheme, host: host}) do
    scheme in ["http", "https"] and filled_string?(host)
  end

  defp valid_absolute_url?(_uri), do: false

  defp pr_repository_matches?(repository, url_repository) do
    cond do
      is_nil(repository) ->
        true

      is_binary(repository) and is_binary(url_repository) ->
        normalize_repository(repository) == normalize_repository(url_repository)

      true ->
        false
    end
  end

  defp pr_number_matches?(number, url_number) do
    cond do
      is_nil(number) -> true
      is_integer(number) and is_integer(url_number) -> number == url_number
      true -> false
    end
  end

  defp normalize_repository(repository) when is_binary(repository) do
    repository
    |> String.trim()
    |> String.downcase()
  end

  defp closeout_progress_summary(%WorkPackageDelivery{} = delivery, closeout_context) do
    if closeout_context.active_blocker_ids != [] do
      "Recorded WorkRequest delivery closeout: #{delivery.outcome} (active blockers cleared)"
    else
      "Recorded WorkRequest delivery closeout: #{delivery.outcome}"
    end
  end

  defp closeout_progress_payload(
         %WorkRequest{} = work_request,
         %WorkPackage{} = work_package,
         %WorkPackageDelivery{} = delivery,
         closeout,
         closeout_context
       ) do
    %{
      type: "work_request_delivery_closeout",
      source_tool: "record_work_package_delivery",
      work_request_id: work_request.id,
      work_package_id: work_package.id,
      delivery_id: delivery.id,
      outcome: delivery.outcome,
      previous_status: closeout.previous_status,
      next_status: closeout.next_status,
      status_changed: closeout.changed?,
      pr_url: delivery.pr_url,
      pr_number: delivery.pr_number,
      pr_repository: delivery.pr_repository,
      pr_merged_at: delivery.pr_merged_at,
      merge_commit_sha: delivery.merge_commit_sha,
      successor_work_package_id: delivery.successor_work_package_id
    }
    |> put_non_empty(:active_blocker_ids, closeout_context.active_blocker_ids)
    |> put_non_empty(:blocker_reason_codes, closeout_context.blocker_reason_codes)
    |> put_non_empty(:runtime_reason_codes_before_closeout, closeout_context.runtime_reason_codes)
    |> put_non_empty(:ignored_stale_agent_run_ids, closeout_context.ignored_stale_agent_run_ids)
    |> put_non_empty(:retired_worker_grant_ids, closeout_context.retired_worker_grant_ids)
    |> put_non_empty(:retired_claim_lease_ids, closeout_context.retired_claim_lease_ids)
  end

  defp put_non_empty(payload, _key, []), do: payload
  defp put_non_empty(payload, key, values) when is_list(values), do: Map.put(payload, key, values)

  defp closeout_idempotency_key(%WorkPackageDelivery{} = delivery) do
    Enum.join(
      [
        "work_request_delivery_closeout",
        delivery.work_request_id,
        delivery.work_package_id,
        delivery.idempotency_key
      ],
      ":"
    )
  end

  defp filled_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp filled_string?(_value), do: false

  defp map_value(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp normalize_transaction_result({:ok, delivery}), do: {:ok, delivery}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint})
       when is_binary(constraint) do
    {:error, {:constraint_failed, constraint}}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    if String.contains?(normalized_message, "busy") or
         String.contains?(normalized_message, "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end
end
