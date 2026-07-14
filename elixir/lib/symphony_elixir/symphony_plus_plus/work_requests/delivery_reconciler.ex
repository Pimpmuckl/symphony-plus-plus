defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryReconciler do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequest
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.PullRequestProgress
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSliceDelivery
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkPackageActivity
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query

  @default_recorded_by "work_request_delivery_reconciler"
  @terminal_without_pr_reason "no_structured_pr_merge_evidence"
  @blocker_closeout_repair_tools ["record_planned_slice_delivery", "reconcile_work_request"]

  @type mode :: :dry_run | :apply
  @type result :: map()

  @spec reconcile(module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile(repo, work_request_id, opts \\ []) when is_atom(repo) and is_binary(work_request_id) and is_list(opts) do
    with {:ok, mode} <- mode(Keyword.get(opts, :mode, :dry_run)),
         {:ok, work_request} <- work_request(repo, work_request_id, opts),
         {:ok, planned_slices} <- planned_slices(repo, work_request_id, opts),
         {:ok, delivery_outcomes} <- delivery_outcomes(repo, planned_slices) do
      results = Enum.map(planned_slices, &reconcile_slice(repo, work_request, &1, delivery_outcomes, mode, opts))

      with {:ok, final_planned_slices} <-
             final_board_planned_slices(repo, work_request_id, planned_slices, mode),
           {:ok, final_board} <-
             delivery_board(repo, work_request, final_planned_slices, final_board_opts(mode, opts)) do
        {:ok, summary(work_request.id, mode, results, final_board)}
      end
    end
  end

  @spec reconcile_work_package(module(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def reconcile_work_package(repo, work_package_id, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_list(opts) do
    case repo.one(from(planned_slice in PlannedSlice, where: planned_slice.work_package_id == ^work_package_id, limit: 1)) do
      nil ->
        {:ok, %{status: "not_linked", work_package_id: work_package_id}}

      %PlannedSlice{} = planned_slice ->
        opts = opts |> Keyword.put(:mode, :apply) |> Keyword.put(:planned_slices, [planned_slice])
        reconcile(repo, planned_slice.work_request_id, opts)
    end
  end

  defp mode(:dry_run), do: {:ok, :dry_run}
  defp mode("dry_run"), do: {:ok, :dry_run}
  defp mode("dry-run"), do: {:ok, :dry_run}
  defp mode(:apply), do: {:ok, :apply}
  defp mode("apply"), do: {:ok, :apply}
  defp mode(_mode), do: {:error, :invalid_reconciliation_mode}

  defp final_board_opts(:apply, opts), do: Keyword.delete(opts, :work_package_contexts)
  defp final_board_opts(:dry_run, opts), do: opts

  defp final_board_planned_slices(repo, work_request_id, _planned_slices, :apply), do: WorkRequestService.list_planned_slices(repo, work_request_id)
  defp final_board_planned_slices(_repo, _work_request_id, planned_slices, :dry_run), do: {:ok, planned_slices}

  defp work_request(repo, work_request_id, opts) do
    case Keyword.get(opts, :work_request) do
      %WorkRequest{id: ^work_request_id} = work_request -> {:ok, work_request}
      nil -> WorkRequestService.get(repo, work_request_id)
      _work_request -> {:error, :not_found}
    end
  end

  defp planned_slices(repo, work_request_id, opts) do
    case Keyword.get(opts, :planned_slices) do
      planned_slices when is_list(planned_slices) ->
        if Enum.all?(planned_slices, &(&1.work_request_id == work_request_id)) do
          {:ok, planned_slices}
        else
          {:error, :not_found}
        end

      nil ->
        WorkRequestService.list_planned_slices(repo, work_request_id)

      _planned_slices ->
        {:error, :not_found}
    end
  end

  defp delivery_board(repo, %WorkRequest{} = work_request, planned_slices, opts) do
    DeliveryBoard.project(repo, work_request.id,
      work_request: work_request,
      planned_slices: planned_slices,
      visible_work_package_ids: Keyword.get(opts, :visible_work_package_ids, :all),
      work_package_contexts: Keyword.get(opts, :work_package_contexts, %{})
    )
  end

  defp delivery_outcomes(_repo, []), do: {:ok, %{}}

  defp delivery_outcomes(repo, planned_slices) do
    planned_slice_ids = Enum.map(planned_slices, & &1.id)

    outcomes =
      repo.all(
        from(delivery in PlannedSliceDelivery,
          where: delivery.planned_slice_id in ^planned_slice_ids,
          select: {delivery.planned_slice_id, delivery.outcome}
        )
      )
      |> Map.new()

    {:ok, outcomes}
  end

  defp reconcile_slice(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, delivery_outcomes, mode, opts) do
    case Map.fetch(delivery_outcomes, planned_slice.id) do
      {:ok, delivery_outcome} ->
        reconcile_already_closed_slice(repo, planned_slice, delivery_outcome, mode, opts)

      :error ->
        cond do
          planned_slice.status != "dispatched" ->
            skipped_result(planned_slice, nil, "not_dispatched")

          not filled_string?(planned_slice.work_package_id) ->
            skipped_result(planned_slice, nil, "missing_linked_work_package")

          not visible_work_package?(planned_slice.work_package_id, Keyword.get(opts, :visible_work_package_ids, :all)) ->
            skipped_result(planned_slice, nil, "work_package_out_of_scope")

          true ->
            reconcile_dispatched_slice(repo, work_request, planned_slice, mode, opts)
        end
    end
  end

  defp reconcile_already_closed_slice(repo, %PlannedSlice{} = planned_slice, delivery_outcome, :apply, opts) do
    cond do
      not filled_string?(planned_slice.work_package_id) ->
        already_closeout_result(planned_slice, nil, delivery_outcome)

      not visible_work_package?(planned_slice.work_package_id, Keyword.get(opts, :visible_work_package_ids, :all)) ->
        already_closeout_result(planned_slice, nil, delivery_outcome)

      true ->
        repair_already_closed_blocker_closeout(repo, planned_slice, delivery_outcome, opts)
    end
  end

  defp reconcile_already_closed_slice(repo, %PlannedSlice{} = planned_slice, delivery_outcome, :dry_run, opts) do
    cond do
      not filled_string?(planned_slice.work_package_id) ->
        already_closeout_result(planned_slice, nil, delivery_outcome)

      not visible_work_package?(planned_slice.work_package_id, Keyword.get(opts, :visible_work_package_ids, :all)) ->
        already_closeout_result(planned_slice, nil, delivery_outcome)

      true ->
        preview_already_closed_blocker_closeout(repo, planned_slice, delivery_outcome, opts)
    end
  end

  defp repair_already_closed_blocker_closeout(repo, %PlannedSlice{} = planned_slice, delivery_outcome, opts) do
    case load_already_closed_blocker_closeout_repair(repo, planned_slice, delivery_outcome) do
      {:ok, work_package, missing_blockers} ->
        append_missing_reconcile_blocker_closeout_events(
          repo,
          planned_slice,
          work_package,
          delivery_outcome,
          missing_blockers,
          opts
        )

      :skip ->
        already_closeout_result(planned_slice, nil, delivery_outcome)

      {:error, reason} ->
        error_result(planned_slice, nil, reason)
    end
  end

  defp preview_already_closed_blocker_closeout(repo, %PlannedSlice{} = planned_slice, delivery_outcome, _opts) do
    case load_already_closed_blocker_closeout_repair(repo, planned_slice, delivery_outcome) do
      {:ok, work_package, []} ->
        already_closeout_result(planned_slice, work_package, delivery_outcome)

      {:ok, work_package, missing_blockers} ->
        closeout = reconcile_still_active_blocker_closeout(missing_blockers, delivery_outcome)

        planned_slice
        |> base_result(work_package)
        |> Map.merge(%{
          status: "proposed",
          reason: "already_closeout_blocker_closeout_repair",
          action: already_closed_action_payload(planned_slice, delivery_outcome, closeout),
          delivery_outcome: delivery_outcome
        })

      :skip ->
        already_closeout_result(planned_slice, nil, delivery_outcome)

      {:error, reason} ->
        error_result(planned_slice, nil, reason)
    end
  end

  defp load_already_closed_blocker_closeout_repair(repo, %PlannedSlice{} = planned_slice, delivery_outcome) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, planned_slice.work_package_id),
         {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package.id),
         {:ok, closeout_event} <- delivery_closeout_event(progress_events, planned_slice, delivery_outcome) do
      missing_blockers =
        progress_events
        |> closeout_blockers(closeout_event)
        |> then(&missing_reconcile_blocker_closeout_blockers(repo, &1))

      {:ok, work_package, missing_blockers}
    else
      {:error, :not_found} -> :skip
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_missing_reconcile_blocker_closeout_events(
         _repo,
         %PlannedSlice{} = planned_slice,
         work_package,
         delivery_outcome,
         [],
         _opts
       ) do
    already_closeout_result(planned_slice, work_package, delivery_outcome)
  end

  defp append_missing_reconcile_blocker_closeout_events(
         repo,
         %PlannedSlice{} = planned_slice,
         work_package,
         delivery_outcome,
         missing_blockers,
         opts
       ) do
    closeout = reconcile_still_active_blocker_closeout(missing_blockers, delivery_outcome)
    action_payload = already_closed_action_payload(planned_slice, delivery_outcome, closeout)

    case append_reconcile_blocker_closeout_events_for_blockers(repo, missing_blockers, closeout, opts) do
      {:ok, event_ids} ->
        planned_slice
        |> base_result(work_package)
        |> Map.merge(%{
          status: "applied",
          reason: "already_closeout_blocker_closeout_repaired",
          action: action_payload,
          delivery_outcome: delivery_outcome
        })
        |> maybe_put_blocker_closeout_event_ids(event_ids)

      {:partial, event_ids, reason} ->
        planned_slice
        |> base_result(work_package)
        |> Map.merge(%{
          status: "applied",
          reason: "already_closeout_blocker_closeout_repaired",
          action: action_payload,
          delivery_outcome: delivery_outcome
        })
        |> maybe_put_blocker_closeout_event_ids(event_ids)
        |> maybe_put_blocker_closeout_repair(%{status: "deferred", reason: reason_text(reason)})

      {:error, reason} ->
        error_result(planned_slice, work_package, reason, action_payload)
    end
  end

  defp already_closeout_result(%PlannedSlice{} = planned_slice, work_package, delivery_outcome) do
    skipped_result(planned_slice, work_package, "already_closeout", delivery_outcome: delivery_outcome)
  end

  defp already_closed_action_payload(%PlannedSlice{} = planned_slice, delivery_outcome, closeout) do
    %{
      work_request_id: planned_slice.work_request_id,
      planned_slice_id: planned_slice.id,
      outcome: delivery_outcome,
      blocker_closeout: closeout
    }
  end

  defp reconcile_still_active_blocker_closeout(blockers, delivery_outcome) do
    %{
      decision: "still_active",
      blocker_ids: Enum.map(blockers, & &1.id),
      summary: "Preserve active blockers while repairing #{delivery_outcome_label(delivery_outcome)} delivery closeout."
    }
  end

  defp delivery_outcome_label("pr_merged"), do: "merged PR"
  defp delivery_outcome_label(outcome) when is_binary(outcome), do: String.replace(outcome, "_", " ")
  defp delivery_outcome_label(_outcome), do: "planned-slice"

  defp missing_reconcile_blocker_closeout_blockers(repo, blockers) do
    Enum.reject(blockers, fn blocker ->
      blocker_closeout_event_exists?(repo, blocker, "still_active")
    end)
  end

  defp blocker_closeout_event_exists?(repo, blocker, decision) do
    idempotency_keys =
      Enum.map(@blocker_closeout_repair_tools, &blocker_closeout_idempotency_key(&1, blocker, decision))

    repo.exists?(
      from(event in ProgressEvent,
        where: event.work_package_id == ^blocker.work_package_id,
        where: event.idempotency_key in ^idempotency_keys
      )
    )
  end

  defp delivery_closeout_event(progress_events, %PlannedSlice{} = planned_slice, delivery_outcome) do
    progress_events
    |> Enum.reverse()
    |> Enum.find(&delivery_closeout_event?(&1, planned_slice.id, delivery_outcome))
    |> case do
      %ProgressEvent{} = event -> {:ok, event}
      nil -> {:error, :not_found}
    end
  end

  defp delivery_closeout_event?(%ProgressEvent{} = event, planned_slice_id, delivery_outcome) do
    payload = event.payload || %{}

    Map.get(payload, "type") == "work_request_delivery_closeout" and
      Map.get(payload, "source_tool") == "record_planned_slice_delivery" and
      Map.get(payload, "planned_slice_id") == planned_slice_id and
      Map.get(payload, "outcome") == delivery_outcome
  end

  defp closeout_blockers(progress_events, %ProgressEvent{} = closeout_event) do
    closeout_blocker_ids =
      closeout_event
      |> closeout_active_blocker_ids()
      |> MapSet.new()

    progress_events
    |> Enum.filter(&progress_event_observed_by?(&1, closeout_event))
    |> BlockerProjection.blockers()
    |> Enum.filter(&(&1.active and MapSet.member?(closeout_blocker_ids, &1.id)))
    |> Enum.map(&Map.put(&1, :work_package_id, closeout_event.work_package_id))
  end

  defp closeout_active_blocker_ids(%ProgressEvent{} = closeout_event) do
    closeout_event.payload
    |> map_value("active_blocker_ids")
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp progress_event_observed_by?(%ProgressEvent{sequence: sequence}, %ProgressEvent{sequence: closeout_sequence})
       when is_integer(sequence) and is_integer(closeout_sequence) do
    sequence <= closeout_sequence
  end

  defp progress_event_observed_by?(%ProgressEvent{}, %ProgressEvent{}), do: false

  defp reconcile_dispatched_slice(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, mode, opts) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, planned_slice.work_package_id),
         {:ok, action} <- closeout_action(repo, work_request, planned_slice, work_package, opts) do
      maybe_apply_action(repo, work_request, planned_slice, work_package, action, mode, opts)
    else
      {:skip, reason, extras} -> skipped_result(planned_slice, nil, reason, extras)
      {:error, :not_found} -> skipped_result(planned_slice, nil, "missing_linked_work_package")
      {:error, reason} -> error_result(planned_slice, nil, reason)
    end
  end

  defp closeout_action(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, %WorkPackage{} = work_package, opts) do
    with {:ok, events} <- PlanningRepository.list_progress_events(repo, work_package.id),
         {:ok, evidence} <- merged_pr_evidence(events),
         :ok <- validate_repository(work_package, evidence),
         :ok <- validate_base_branch(planned_slice, work_package, evidence),
         :ok <- validate_head(events, evidence),
         {:ok, merged_at} <- required_merged_at(evidence),
         {:ok, merge_commit_sha} <- required_merge_commit_sha(evidence) do
      {:ok,
       %{
         outcome: "pr_merged",
         reason: "github_pr_merged",
         attrs: %{
           outcome: "pr_merged",
           idempotency_key: idempotency_key(work_request, planned_slice, evidence, merge_commit_sha),
           recorded_by: Keyword.get(opts, :recorded_by, @default_recorded_by),
           pr_url: evidence.url,
           pr_number: evidence.number,
           pr_repository: evidence.repository,
           pr_merged_at: merged_at,
           merge_commit_sha: merge_commit_sha
         },
         evidence: %{
           source_tool: evidence.source_tool,
           pr_url: evidence.url,
           pr_repository: evidence.repository,
           pr_number: evidence.number,
           head_sha: evidence.head_sha,
           base_branch: evidence.base_branch
         }
       }}
    else
      {:skip, _reason, _extras} = skip -> skip
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_apply_action(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, %WorkPackage{} = work_package, action, :dry_run, _opts) do
    action_payload = action_payload(repo, work_request, planned_slice, work_package, action)

    planned_slice
    |> base_result(work_package)
    |> Map.merge(%{
      status: "proposed",
      reason: action.reason,
      action: action_payload,
      evidence: action.evidence
    })
  end

  defp maybe_apply_action(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, %WorkPackage{} = work_package, action, :apply, opts) do
    action_payload = action_payload(repo, work_request, planned_slice, work_package, action)
    delivery_attrs = delivery_attrs(repo, work_package, action)

    case record_reconciled_delivery(
           repo,
           work_request,
           planned_slice,
           work_package,
           delivery_attrs,
           action_payload,
           opts
         ) do
      {:ok, delivery, blocker_closeout_event_ids, blocker_closeout_repair} ->
        planned_slice
        |> base_result(work_package)
        |> Map.merge(%{
          status: "applied",
          reason: action.reason,
          action: action_payload,
          evidence: action.evidence,
          delivery_id: delivery.id
        })
        |> maybe_put_blocker_closeout_event_ids(blocker_closeout_event_ids)
        |> maybe_put_blocker_closeout_repair(blocker_closeout_repair)

      {:error, reason} ->
        error_result(planned_slice, work_package, reason, action_payload)
    end
  end

  defp merged_pr_evidence(events) do
    events = PullRequestProgress.chronological_events(events)

    case PullRequestProgress.current_pr_state(events, ["attach_pr"]) do
      {:ok, pr_state} ->
        pr_sync = latest_pr_snapshot(events, pr_state.ref, ["sync_pr"])
        merge_reconciliation = latest_merge_reconciliation(events, pr_state.ref)

        if PullRequestProgress.merged?(pr_state.payload) or PullRequestProgress.merged?(pr_sync) or
             merge_reconciliation_payload?(merge_reconciliation) do
          {:ok, evidence_from(pr_state.payload, pr_sync, merge_reconciliation, pr_state.ref)}
        else
          {:skip, @terminal_without_pr_reason, %{}}
        end

      {:error, :missing_attached_pr} ->
        {:skip, @terminal_without_pr_reason, %{}}

      {:error, reason} ->
        {:skip, Atom.to_string(reason), %{}}
    end
  end

  defp latest_pr_snapshot(events, ref, source_tools) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn %ProgressEvent{} = event ->
      payload = PullRequestProgress.stringify_keys(event.payload || %{})

      if pr_snapshot_payload?(payload, source_tools) and PullRequestProgress.same_pr?(payload, ref) do
        payload
      end
    end)
  end

  defp latest_merge_reconciliation(events, ref) do
    events
    |> Enum.reverse()
    |> Enum.find_value(fn %ProgressEvent{} = event ->
      payload = PullRequestProgress.stringify_keys(event.payload || %{})

      if merge_reconciliation_payload?(payload) and PullRequestProgress.same_pr?(payload, ref) do
        payload
      end
    end)
  end

  defp pr_snapshot_payload?(%{"type" => "pr", "source_tool" => source_tool}, source_tools) do
    source_tool in source_tools
  end

  defp pr_snapshot_payload?(_payload, _source_tools), do: false

  defp evidence_from(pr_payload, pr_sync, merge_payload, ref) do
    source_tool =
      first_present([
        map_value(merge_payload, "source_tool"),
        map_value(pr_sync, "source_tool"),
        map_value(pr_payload, "source_tool")
      ])

    base_branch_values = [map_value(pr_sync, "base_branch"), map_value(pr_payload, "base_branch")]
    head_sha_values = [map_value(merge_payload, "head_sha"), map_value(pr_sync, "head_sha"), map_value(pr_payload, "head_sha")]
    merged_at_values = [map_value(pr_sync, "merged_at"), map_value(merge_payload, "merged_at"), map_value(pr_payload, "merged_at")]

    base_branch = clean_string(first_present(base_branch_values))
    head_sha = clean_string(first_present(head_sha_values))
    merged_at = first_present(merged_at_values)

    merge_commit_sha =
      first_present([
        map_value(pr_sync, "merge_commit_sha"),
        map_value(merge_payload, "merge_commit_sha"),
        map_value(pr_payload, "merge_commit_sha")
      ])

    %{
      source_tool: source_tool,
      url: ref.url,
      repository: ref.repository,
      number: ref.number,
      ref: ref,
      base_branch: base_branch,
      head_sha: head_sha,
      merged_at: merged_at,
      merge_commit_sha: merge_commit_sha
    }
  end

  defp validate_repository(%WorkPackage{} = work_package, evidence) do
    expected = normalize_repository(work_package.repo)
    actual = normalize_repository(evidence.repository)

    cond do
      is_nil(expected) or is_nil(actual) ->
        {:skip, "missing_repository", %{expected_repository: work_package.repo, actual_repository: evidence.repository}}

      expected != actual ->
        {:skip, "repository_mismatch", %{expected_repository: work_package.repo, actual_repository: evidence.repository}}

      true ->
        :ok
    end
  end

  defp validate_base_branch(%PlannedSlice{} = planned_slice, %WorkPackage{}, evidence) do
    expected = clean_string(planned_slice.target_base_branch)
    actual = clean_string(evidence.base_branch)

    cond do
      is_nil(expected) or is_nil(actual) ->
        {:skip, "missing_base_branch", %{expected_base_branch: expected, actual_base_branch: actual}}

      expected != actual ->
        {:skip, "base_branch_mismatch", %{expected_base_branch: expected, actual_base_branch: actual}}

      true ->
        :ok
    end
  end

  defp validate_head(events, %{ref: ref} = evidence) when is_map(ref) do
    case PullRequestProgress.expected_head_sha(events, ref) do
      expected when is_binary(expected) ->
        if PullRequest.head_sha_matches?(evidence.head_sha, expected) do
          :ok
        else
          {:skip, "head_mismatch", %{expected_head_sha: expected, actual_head_sha: evidence.head_sha}}
        end

      _missing ->
        {:skip, "missing_head_evidence", %{actual_head_sha: evidence.head_sha}}
    end
  end

  defp required_merged_at(evidence) do
    case parse_datetime(evidence.merged_at) do
      {:ok, datetime} -> {:ok, datetime}
      :error -> {:skip, "missing_strong_pr_evidence", %{missing: "pr_merged_at"}}
    end
  end

  defp required_merge_commit_sha(evidence) do
    case clean_string(evidence.merge_commit_sha) do
      nil -> {:skip, "missing_strong_pr_evidence", %{missing: "merge_commit_sha"}}
      merge_commit_sha -> {:ok, merge_commit_sha}
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: {:ok, DateTime.truncate(datetime, :microsecond)}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(String.trim(value)) do
      {:ok, datetime, _offset} -> {:ok, DateTime.truncate(datetime, :microsecond)}
      _error -> :error
    end
  end

  defp parse_datetime(_value), do: :error

  defp merge_reconciliation_payload?(%{"type" => "github_pr_merge_reconciliation", "source_tool" => "operator_sync_prs"} = payload) do
    PullRequestProgress.merged?(payload)
  end

  defp merge_reconciliation_payload?(_payload), do: false

  defp action_payload(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, %WorkPackage{} = work_package, action) do
    %{
      work_request_id: work_request.id,
      planned_slice_id: planned_slice.id,
      outcome: action.attrs.outcome,
      idempotency_key: action.attrs.idempotency_key,
      recorded_by: action.attrs.recorded_by,
      evidence: %{
        pr_merged: %{
          pr_url: action.attrs.pr_url,
          pr_number: action.attrs.pr_number,
          pr_repository: action.attrs.pr_repository,
          pr_merged_at: action.attrs.pr_merged_at,
          merge_commit_sha: action.attrs.merge_commit_sha
        }
      }
    }
    |> maybe_put_blocker_closeout(repo, work_package)
  end

  defp maybe_put_blocker_closeout(payload, repo, %WorkPackage{} = work_package) do
    case active_blocker_ids(repo, work_package.id) do
      [] ->
        payload

      blocker_ids ->
        Map.put(payload, :blocker_closeout, %{
          decision: "still_active",
          blocker_ids: blocker_ids,
          summary: "Preserve active blockers while recording merged PR delivery."
        })
    end
  end

  defp active_blocker_ids(repo, work_package_id) do
    repo
    |> WorkPackageActivity.context(work_package_id)
    |> get_in([:blocker_state, :active_ids])
    |> List.wrap()
  end

  defp delivery_attrs(repo, %WorkPackage{} = work_package, action) do
    case active_blocker_ids(repo, work_package.id) do
      [] -> action.attrs
      _blocker_ids -> Map.put(action.attrs, "allow_active_blocker_closeout", true)
    end
  end

  defp append_reconcile_blocker_closeout_events(
         repo,
         %WorkPackage{} = work_package,
         %{
           blocker_closeout: %{blocker_ids: blocker_ids} = closeout
         },
         opts
       )
       when is_list(blocker_ids) do
    with {:ok, active_blockers} <- active_blockers(repo, work_package.id),
         {:ok, closeout_blockers} <- reconcile_closeout_blockers(active_blockers, blocker_ids) do
      append_reconcile_blocker_closeout_events_for_blockers(repo, closeout_blockers, closeout, opts)
    end
  end

  defp append_reconcile_blocker_closeout_events(_repo, %WorkPackage{}, _action_payload, _opts), do: {:ok, []}

  defp append_reconcile_blocker_closeout_events_for_blockers(repo, blockers, closeout, opts) do
    Enum.reduce_while(blockers, {:ok, []}, fn blocker, {:ok, event_ids} ->
      append_reconcile_blocker_closeout_event_result(repo, blocker, closeout, event_ids, opts)
    end)
  end

  defp append_reconcile_blocker_closeout_event_result(repo, blocker, closeout, event_ids, opts) do
    case append_reconcile_blocker_closeout_event(repo, blocker, closeout, opts) do
      {:ok, event} -> {:cont, {:ok, [event.id | event_ids]}}
      {:error, reason} when event_ids == [] -> {:halt, {:error, reason}}
      {:error, reason} -> {:halt, {:partial, event_ids, reason}}
    end
  end

  defp active_blockers(repo, work_package_id) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package_id) do
      blockers =
        progress_events
        |> BlockerProjection.blockers()
        |> Enum.filter(& &1.active)
        |> Enum.map(&Map.put(&1, :work_package_id, work_package_id))

      {:ok, blockers}
    end
  end

  defp reconcile_closeout_blockers(active_blockers, []) do
    {:ok, active_blockers}
  end

  defp reconcile_closeout_blockers(active_blockers, blocker_ids) do
    active_by_id = Map.new(active_blockers, &{&1.id, &1})
    active_ids = active_by_id |> Map.keys() |> Enum.sort()
    missing_ids = Enum.reject(blocker_ids, &Map.has_key?(active_by_id, &1))

    case missing_ids do
      [] -> {:ok, Enum.map(blocker_ids, &Map.fetch!(active_by_id, &1))}
      _missing -> {:error, {:blocker_closeout_scope_mismatch, active_ids, Enum.sort(blocker_ids)}}
    end
  end

  defp record_reconciled_delivery(
         repo,
         %WorkRequest{} = work_request,
         %PlannedSlice{} = planned_slice,
         %WorkPackage{} = work_package,
         delivery_attrs,
         action_payload,
         opts
       ) do
    with {:ok, delivery} <-
           record_planned_slice_delivery(repo, work_request, planned_slice, delivery_attrs, opts) do
      case append_reconcile_blocker_closeout_events(repo, work_package, action_payload, opts) do
        {:ok, blocker_closeout_event_ids} ->
          {:ok, delivery, blocker_closeout_event_ids, nil}

        {:partial, blocker_closeout_event_ids, reason} ->
          {:ok, delivery, blocker_closeout_event_ids, %{status: "deferred", reason: reason_text(reason)}}

        {:error, reason} ->
          {:ok, delivery, [], %{status: "deferred", reason: reason_text(reason)}}
      end
    end
  end

  defp record_planned_slice_delivery(repo, %WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, attrs, opts) do
    case Keyword.get(opts, :record_planned_slice_delivery) do
      fun when is_function(fun, 4) -> fun.(repo, work_request.id, planned_slice.id, attrs)
      _missing -> WorkRequestService.record_planned_slice_delivery(repo, work_request.id, planned_slice.id, attrs)
    end
  end

  defp append_reconcile_blocker_closeout_event(repo, blocker, closeout, opts) do
    attrs = %{
      work_package_id: blocker.work_package_id,
      summary: reconcile_blocker_closeout_summary(closeout),
      status: "blocked",
      idempotency_key: reconcile_blocker_closeout_idempotency_key(blocker, "still_active"),
      payload: %{
        type: "blocker_closeout_decision",
        source_tool: "reconcile_work_request",
        blocker_id: blocker.id,
        decision: "still_active"
      }
    }

    append_reconcile_blocker_closeout_event_attrs(repo, blocker.work_package_id, attrs, opts)
  end

  defp reconcile_blocker_closeout_summary(closeout) do
    case Map.get(closeout, :summary) do
      summary when is_binary(summary) and summary != "" -> summary
      _summary -> "Preserved active blocker during reconcile_work_request"
    end
  end

  defp append_reconcile_blocker_closeout_event_attrs(repo, work_package_id, attrs, opts) do
    case Keyword.get(opts, :append_blocker_closeout_event) do
      fun when is_function(fun, 3) -> fun.(repo, work_package_id, attrs)
      _missing -> PlanningRepository.append_progress_event(repo, attrs)
    end
  end

  defp reconcile_blocker_closeout_idempotency_key(blocker, decision) do
    blocker_closeout_idempotency_key("reconcile_work_request", blocker, decision)
  end

  defp blocker_closeout_idempotency_key(tool, blocker, decision) do
    ["blocker_closeout", tool, blocker.work_package_id, blocker.id, blocker.event_id, decision]
    |> Enum.join(":")
  end

  defp maybe_put_blocker_closeout_event_ids(result, []), do: result
  defp maybe_put_blocker_closeout_event_ids(result, event_ids), do: Map.put(result, :blocker_closeout_event_ids, Enum.reverse(event_ids))

  defp maybe_put_blocker_closeout_repair(result, nil), do: result
  defp maybe_put_blocker_closeout_repair(result, repair), do: Map.put(result, :blocker_closeout_repair, repair)

  defp idempotency_key(%WorkRequest{} = work_request, %PlannedSlice{} = planned_slice, evidence, merge_commit_sha) do
    material = [work_request.id, planned_slice.id, evidence.url, evidence.head_sha, merge_commit_sha] |> Enum.join(":")
    "delivery_reconciler:" <> Base.url_encode64(:crypto.hash(:sha256, material), padding: false)
  end

  defp base_result(%PlannedSlice{} = planned_slice, %WorkPackage{} = work_package) do
    %{
      work_request_id: planned_slice.work_request_id,
      planned_slice_id: planned_slice.id,
      work_package_id: planned_slice.work_package_id,
      work_package_status: work_package.status
    }
  end

  defp base_result(%PlannedSlice{} = planned_slice, _work_package) do
    %{
      work_request_id: planned_slice.work_request_id,
      planned_slice_id: planned_slice.id,
      work_package_id: planned_slice.work_package_id
    }
  end

  defp skipped_result(%PlannedSlice{} = planned_slice, work_package, reason, extras \\ %{}) do
    planned_slice
    |> base_result(work_package)
    |> Map.merge(%{status: "skipped", reason: reason})
    |> Map.merge(Map.new(extras))
  end

  defp error_result(%PlannedSlice{} = planned_slice, work_package, reason, action \\ nil) do
    planned_slice
    |> base_result(work_package)
    |> Map.merge(%{status: "error", reason: reason_text(reason), action: action})
  end

  defp visible_work_package?(_work_package_id, :all), do: true
  defp visible_work_package?(_work_package_id, nil), do: true
  defp visible_work_package?(work_package_id, visible_ids) when is_list(visible_ids), do: work_package_id in visible_ids

  defp visible_work_package?(_work_package_id, _visible_ids), do: false

  defp summary(work_request_id, mode, results, delivery_board) do
    %{
      work_request_id: work_request_id,
      mode: Atom.to_string(mode),
      total_count: length(results),
      proposed_count: Enum.count(results, &(&1.status == "proposed")),
      applied_count: Enum.count(results, &(&1.status == "applied")),
      skipped_count: Enum.count(results, &(&1.status == "skipped")),
      error_count: Enum.count(results, &(&1.status == "error")),
      results: results,
      delivery_board: delivery_board
    }
  end

  defp map_value(nil, _key), do: nil
  defp map_value(%{} = map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp first_present(values) do
    Enum.find(values, fn
      value when is_binary(value) -> String.trim(value) != ""
      nil -> false
      _value -> true
    end)
  end

  defp normalize_repository(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> nil
      repository -> repository
    end
  end

  defp normalize_repository(_value), do: nil

  defp clean_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean_string(_value), do: nil

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
