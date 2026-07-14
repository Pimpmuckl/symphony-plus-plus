defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.OperationalProjection do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.{
    BlockerProjection,
    DeliverySliceProjection,
    MetadataProjection,
    Sanitizer
  }

  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice

  @stale_heartbeat_after_seconds 300
  @ready_statuses ["ready_for_merge", "ready_for_human_merge", "ready_for_architect_merge"]
  @complete_plan_statuses ["done", "completed", "skipped"]
  @merge_required_gates ["human_merge", "architect_merge"]
  @runtime_merge_required_kinds ["hotfix", "adapter", "mcp", "skill", "hooks", "phase_child"]
  @started_package_statuses ["claimed", "planning", "implementing"]
  @prepared_worktree_statuses ["prepared", "already_prepared"]
  @merged_package_statuses ["merged", "merged_into_phase"]
  @closed_package_statuses ["closed", "abandoned"]
  @scope_guard_gate "scope_guard"

  @type repo :: module()

  @spec runtime_summary([AgentRun.t()]) :: map()
  def runtime_summary(agent_runs) do
    runs = Enum.map(agent_runs, &agent_run/1)

    %{
      stale_heartbeat_after_seconds: @stale_heartbeat_after_seconds,
      active_count: Enum.count(runs, &(&1.runtime_state == "active")),
      queued_count: Enum.count(runs, &(&1.runtime_state == "queued")),
      stopped_count: Enum.count(runs, &(&1.runtime_state == "stopped")),
      failed_count: Enum.count(runs, &(&1.status == "failed")),
      completed_count: Enum.count(runs, &(&1.status == "completed")),
      terminal_count: Enum.count(runs, &(&1.runtime_state in ["stopped", "terminal"])),
      stale_count: Enum.count(runs, & &1.stale)
    }
  end

  @spec stale_agent_run?(AgentRun.t()) :: boolean()
  def stale_agent_run?(%AgentRun{} = run) do
    stale_agent_run?(run, DateTime.utc_now(:microsecond), @stale_heartbeat_after_seconds)
  end

  @spec stale_agent_run?(AgentRun.t(), DateTime.t(), non_neg_integer()) :: boolean()
  def stale_agent_run?(%AgentRun{status: status, last_seen_at: %DateTime{} = last_seen_at}, %DateTime{} = now, threshold_seconds)
      when status in ["starting", "running", "retrying"] and is_integer(threshold_seconds) and threshold_seconds >= 0 do
    DateTime.diff(now, last_seen_at, :second) >= threshold_seconds
  end

  def stale_agent_run?(%AgentRun{}, %DateTime{}, _threshold_seconds), do: false

  @spec latest_active_agent_run([AgentRun.t()]) :: map() | nil
  def latest_active_agent_run(agent_runs) do
    agent_runs
    |> latest_active_run()
    |> case do
      %AgentRun{} = run -> agent_run(run)
      nil -> nil
    end
  end

  @spec plan_summary([PlanNode.t()]) :: map()
  def plan_summary(plan_nodes) do
    total = length(plan_nodes)
    completed = Enum.count(plan_nodes, &(&1.status in ["done", "completed", "skipped"]))

    %{
      total_count: total,
      completed_count: completed,
      open_count: max(total - completed, 0)
    }
  end

  @spec work_package_operational_state(WorkPackage.t(), map()) :: map()
  def work_package_operational_state(%WorkPackage{} = work_package, context) do
    agent_runs = Map.fetch!(context, :agent_runs)
    progress_events = Map.fetch!(context, :progress_events)
    blockers = Map.fetch!(context, :blockers)
    runtime = Map.fetch!(context, :runtime)
    metadata = Map.fetch!(context, :metadata)
    readiness_context = Map.fetch!(context, :readiness_context)
    grants = Map.fetch!(context, :grants)
    lineage = Map.fetch!(context, :lineage)
    missing_readiness = if work_package.status in @ready_statuses, do: missing_readiness_evidence(readiness_context), else: []
    activity = work_package_activity(work_package, progress_events, agent_runs, runtime, metadata, grants)

    attention_items =
      work_package_attention_items(work_package, blockers, %{
        metadata: metadata,
        missing_readiness: missing_readiness,
        activity: activity,
        lineage: lineage
      })

    work_package
    |> base_work_package_operational_state(blockers, metadata, missing_readiness, activity)
    |> Map.merge(%{merge_required: merge_required?(work_package), pr_required: pr_required?(work_package)})
    |> Map.merge(operational_activity_fields(activity))
    |> Map.put(:attention_items, attention_items)
  end

  @spec planned_slice_operational_state(PlannedSlice.t(), map() | nil, map() | nil) :: map()
  def planned_slice_operational_state(%PlannedSlice{} = planned_slice, work_package_context, delivery_slice) do
    planned_slice_operational_state(planned_slice, work_package_context, delivery_slice, [])
  end

  @spec planned_slice_operational_state(PlannedSlice.t(), map() | nil, map() | nil, keyword()) :: map()
  def planned_slice_operational_state(%PlannedSlice{} = planned_slice, work_package_context, delivery_slice, delivery_state_opts) do
    base_state = base_planned_slice_operational_state(planned_slice, work_package_context)

    case DeliverySliceProjection.primary_operational_state(delivery_slice, delivery_state_opts) do
      nil -> base_state
      operational_state -> delivery_operational_state_overlay(base_state, operational_state)
    end
  end

  @spec operational_activity_fields(map()) :: map()
  def operational_activity_fields(activity) do
    Map.take(activity, [:has_started, :has_active_worker, :has_prepared_worktree, :last_activity_at, :is_stale])
  end

  @spec alert_indicators(repo(), State.t(), map()) :: [map()]
  @spec alert_indicators(map(), [map()], map()) :: [map()]
  def alert_indicators(repo, %State{} = state, runtime) when is_atom(repo) do
    state
    |> readiness_context(repo, length(state.artifacts), length(state.findings))
    |> alert_indicators(blockers(state.progress_events), runtime)
  end

  def alert_indicators(readiness_context, blockers, runtime) do
    [
      blocker_indicator(readiness_context.work_package, blockers),
      stale_heartbeat_indicator(runtime),
      failed_run_indicator(runtime),
      missing_readiness_indicator(readiness_context),
      scope_drift_indicator(readiness_context)
    ]
  end

  @spec readiness_context(State.t(), repo(), non_neg_integer(), non_neg_integer()) :: map()
  def readiness_context(%State{} = state, repo, _artifact_count, _finding_count) do
    readiness_context(
      repo,
      state.work_package,
      state.plan_nodes,
      state.progress_events,
      state.artifacts,
      state.findings
    )
  end

  @spec readiness_context(repo(), WorkPackage.t(), [PlanNode.t()], [ProgressEvent.t()], [term()], [term()]) :: map()
  def readiness_context(repo, %WorkPackage{} = work_package, plan_nodes, progress_events, artifacts, findings) do
    readiness_context(repo, work_package, plan_nodes, progress_events, artifacts, findings, work_package.review_requirement)
  end

  @spec readiness_context(
          repo(),
          WorkPackage.t(),
          [PlanNode.t()],
          [ProgressEvent.t()],
          [term()],
          [term()],
          term()
        ) :: map()
  def readiness_context(repo, %WorkPackage{} = work_package, plan_nodes, progress_events, artifacts, findings, review_requirement) do
    %{
      repo: repo,
      work_package: work_package,
      plan_nodes: plan_nodes,
      progress_events: chronological_progress_events(progress_events),
      artifacts: artifacts,
      findings: findings,
      review_requirement: review_requirement,
      artifact_count: length(artifacts),
      finding_count: length(findings)
    }
  end

  @spec missing_readiness_evidence(map()) :: [String.t()]
  def missing_readiness_evidence(%{work_package: %WorkPackage{}} = context) do
    context
    |> readiness_failure_reasons()
    |> missing_readiness_gates()
  end

  @spec metadata([ProgressEvent.t()], [term()], String.t()) :: map()
  def metadata(progress_events, artifacts, work_package_id), do: MetadataProjection.metadata(progress_events, artifacts, work_package_id)

  @spec package_lineage(repo(), String.t()) :: map()
  def package_lineage(repo, work_package_id), do: MetadataProjection.package_lineage(repo, work_package_id)

  @spec package_lineages(repo(), [WorkPackage.t()]) :: map()
  def package_lineages(repo, work_packages), do: MetadataProjection.package_lineages(repo, work_packages)

  @spec empty_lineage(String.t()) :: map()
  def empty_lineage(work_package_id), do: MetadataProjection.empty_lineage(work_package_id)

  @spec blockers([ProgressEvent.t()]) :: [map()]
  def blockers(progress_events), do: BlockerProjection.blockers(progress_events)

  @spec agent_run(AgentRun.t()) :: map()
  def agent_run(%AgentRun{} = run) do
    %{
      id: run.id,
      work_package_id: run.work_package_id,
      access_grant_id: run.access_grant_id,
      actor_id: run.actor_id,
      status: run.status,
      runtime_state: runtime_state(run),
      stale: stale_agent_run?(run),
      stale_after_seconds: @stale_heartbeat_after_seconds,
      attempt: run.attempt,
      worker_host: redacted_text(run.worker_host),
      worker_task_handle: redacted_text(run.worker_task_handle),
      workspace_path: redacted_text(run.workspace_path),
      session_id: redacted_text(run.session_id),
      codex_input_tokens: run.codex_input_tokens,
      codex_output_tokens: run.codex_output_tokens,
      codex_total_tokens: run.codex_total_tokens,
      turn_count: run.turn_count,
      started_at: timestamp(run.started_at),
      last_seen_at: timestamp(run.last_seen_at),
      finished_at: timestamp(run.finished_at),
      reason: redacted_text(run.reason)
    }
  end

  defp runtime_state(%AgentRun{status: "starting"}), do: "queued"
  defp runtime_state(%AgentRun{status: status}) when status in ["running", "retrying"], do: "active"
  defp runtime_state(%AgentRun{status: "stopped"}), do: "stopped"
  defp runtime_state(%AgentRun{status: status}) when status in ["completed", "failed"], do: "terminal"
  defp runtime_state(%AgentRun{}), do: "unknown"

  defp latest_active_run(agent_runs) do
    agent_runs
    |> Enum.filter(&(runtime_state(&1) in ["active", "queued"] and not stale_agent_run?(&1)))
    |> List.last()
  end

  defp base_work_package_operational_state(%WorkPackage{status: status} = work_package, blockers, metadata, missing_readiness, activity) do
    active_blocker_count = blockers |> active_blockers() |> length()

    blocking_or_terminal_operational_state(status, active_blocker_count, metadata) ||
      delivery_operational_state(work_package, metadata, missing_readiness, activity)
  end

  defp blocking_or_terminal_operational_state(status, active_blocker_count, metadata) do
    cond do
      active_blocker_count > 0 ->
        operational_state("blocked", "Blocked", "critical", blocker_detail(active_blocker_count), status)

      status == "blocked" ->
        operational_state("blocked", "Blocked", "critical", "Raw lifecycle status is blocked.", status)

      pr_merged?(metadata) and open_package_status?(status) ->
        operational_state("merged", "Merged", "success", "PR metadata reports a merged pull request while raw status is #{status}.", status)

      status in @merged_package_statuses ->
        operational_state("merged", "Merged", "success", "Raw lifecycle status indicates merged delivery.", status)

      status in @closed_package_statuses ->
        operational_state(status, status_label(status), "neutral", "Raw lifecycle status is #{status}.", status)

      true ->
        nil
    end
  end

  defp delivery_operational_state(%WorkPackage{status: status} = work_package, metadata, missing_readiness, activity) do
    validation_operational_state(work_package, metadata, missing_readiness) ||
      pickup_operational_state(status, activity)
  end

  defp validation_operational_state(%WorkPackage{status: status} = work_package, metadata, missing_readiness) do
    cond do
      status == "merging_into_phase" ->
        operational_state("merging", "Merging", "info", "Package is being merged into its phase.", status)

      status in @ready_statuses ->
        ready_operational_state(work_package, missing_readiness)

      status == "ci_waiting" ->
        operational_state("ci_waiting", "CI Waiting", "info", "Package is waiting on validation or CI evidence.", status)

      status == "reviewing" or review_activity?(metadata) ->
        operational_state("reviewing", "Reviewing", "info", "Review evidence or lifecycle status indicates review is active.", status)

      true ->
        nil
    end
  end

  defp ready_operational_state(%WorkPackage{status: status} = work_package, missing_readiness) do
    tone = if missing_readiness == [], do: "success", else: "warning"

    if merge_required?(work_package) do
      reason = if missing_readiness == [], do: "Package is marked ready with required evidence present.", else: "Package is marked ready but evidence is incomplete."
      operational_state("merge_ready", "Ready For Merge", tone, reason, status)
    else
      reason = if missing_readiness == [], do: "Package is ready to finish with closeout evidence.", else: "Package is ready to finish but evidence is incomplete."
      operational_state("ready_to_finish", "Ready To Finish", tone, reason, status)
    end
  end

  defp pickup_operational_state("ready_for_worker" = status, %{has_active_worker: true}) do
    operational_state("active", "Active", "info", "Worker grant or runtime evidence indicates work is active now.", status)
  end

  defp pickup_operational_state("ready_for_worker" = status, %{has_started: true}) do
    operational_state(
      "needs_attention",
      "Needs Attention",
      "warning",
      "Raw status is ready_for_worker but worker, runtime, progress, PR, review, or merge activity is recorded.",
      status
    )
  end

  defp pickup_operational_state("ready_for_worker" = status, %{has_prepared_worktree: true}) do
    operational_state("prepared", "Prepared", "neutral", "Worktree preparation is recorded and the package is awaiting worker claim.", status)
  end

  defp pickup_operational_state(status, %{has_active_worker: true}) when status != "ready_for_worker" do
    operational_state("active", "Active", "info", "Worker grant or runtime evidence indicates work is active now.", status)
  end

  defp pickup_operational_state(status, %{has_started: true}) do
    operational_state(
      "started_paused",
      "Started / Paused",
      "warning",
      "Historical lifecycle, runtime, progress, PR, or review evidence exists, but no active worker or runtime is visible now.",
      status
    )
  end

  defp pickup_operational_state("ready_for_worker" = status, _activity) do
    operational_state(
      "ready_for_worker",
      "Ready For Worker",
      "neutral",
      "No linked delivery, worker, runtime, progress, blocker, review, PR, or merge activity is recorded.",
      status
    )
  end

  defp pickup_operational_state("created" = status, _activity) do
    operational_state("created", "Created", "neutral", "Package has been created but is not ready for worker pickup.", status)
  end

  defp pickup_operational_state(status, _activity) do
    key = status || "unknown"
    operational_state(key, status_label(key), "neutral", "Raw lifecycle status is #{key}.", status)
  end

  defp delivery_operational_state_overlay(base_state, delivery_state) do
    base_state
    |> Map.merge(delivery_state)
    |> Map.put(:attention_items, merged_attention_items(base_state, delivery_state))
  end

  defp merged_attention_items(base_state, delivery_state) do
    (Map.get(base_state, :attention_items, []) ++ Map.get(delivery_state, :attention_items, []))
    |> Enum.uniq_by(&Map.get(&1, :key))
  end

  defp base_planned_slice_operational_state(%PlannedSlice{} = planned_slice, nil) do
    planned_slice
    |> base_unlinked_planned_slice_operational_state()
    |> Map.put(:attention_items, planned_slice_attention_items(planned_slice, nil))
  end

  defp base_planned_slice_operational_state(%PlannedSlice{} = planned_slice, %{card: card, work_package: %WorkPackage{} = work_package}) do
    linked_state = Map.fetch!(card, :operational_state)
    attention_items = planned_slice_attention_items(planned_slice, work_package, linked_state)

    if promoted_linked_operational_state?(linked_state) do
      linked_state
      |> operational_activity_fields()
      |> Map.merge(
        operational_state(
          linked_state.key,
          linked_state.label,
          linked_state.tone,
          "Linked WorkPackage #{work_package.id} is #{linked_state.label}.",
          planned_slice.status,
          attention_items
        )
      )
    else
      linked_idle_planned_slice_operational_state(planned_slice, work_package, attention_items)
    end
  end

  defp base_unlinked_planned_slice_operational_state(%PlannedSlice{status: "approved"} = planned_slice) do
    operational_state("ready_for_worker", "Ready For Worker", "neutral", "Approved slice has no linked WorkPackage or delivery activity.", planned_slice.status)
  end

  defp base_unlinked_planned_slice_operational_state(%PlannedSlice{status: "planned"} = planned_slice) do
    operational_state("planned", "Planned", "neutral", "Slice is planned and has no linked WorkPackage.", planned_slice.status)
  end

  defp base_unlinked_planned_slice_operational_state(%PlannedSlice{status: "skipped"} = planned_slice) do
    operational_state("skipped", "Skipped", "neutral", "Slice was skipped before dispatch.", planned_slice.status)
  end

  defp base_unlinked_planned_slice_operational_state(%PlannedSlice{} = planned_slice) do
    operational_state("dispatched", "Dispatched", "warning", "Slice is marked dispatched but no linked WorkPackage is available.", planned_slice.status)
  end

  defp linked_idle_planned_slice_operational_state(%PlannedSlice{status: "approved"} = planned_slice, %WorkPackage{} = work_package, attention_items) do
    operational_state(
      "ready_for_worker",
      "Ready For Worker",
      "neutral",
      "Approved slice is linked to WorkPackage #{work_package.id}, which has not started.",
      planned_slice.status,
      attention_items
    )
  end

  defp linked_idle_planned_slice_operational_state(%PlannedSlice{status: "planned"} = planned_slice, %WorkPackage{} = work_package, attention_items) do
    operational_state(
      "planned",
      "Planned",
      "neutral",
      "Slice is linked to WorkPackage #{work_package.id}, which has not started.",
      planned_slice.status,
      attention_items
    )
  end

  defp linked_idle_planned_slice_operational_state(%PlannedSlice{status: "skipped"} = planned_slice, %WorkPackage{} = work_package, attention_items) do
    operational_state(
      "skipped",
      "Skipped",
      "neutral",
      "Skipped slice is linked to WorkPackage #{work_package.id}.",
      planned_slice.status,
      attention_items
    )
  end

  defp linked_idle_planned_slice_operational_state(%PlannedSlice{} = planned_slice, %WorkPackage{} = work_package, attention_items) do
    operational_state(
      "dispatched",
      "Dispatched",
      "neutral",
      "Slice is linked to WorkPackage #{work_package.id}, which has not started.",
      planned_slice.status,
      attention_items
    )
  end

  defp planned_slice_attention_items(%PlannedSlice{} = planned_slice, nil) do
    if planned_slice.status == "dispatched" and not filled_string?(planned_slice.work_package_id) do
      [
        %{
          key: "missing_linked_work_package",
          label: "Missing Linked WorkPackage",
          tone: "warning",
          reason: "Slice is marked dispatched without a linked WorkPackage."
        }
      ]
    else
      []
    end
  end

  defp planned_slice_attention_items(%PlannedSlice{} = planned_slice, %WorkPackage{} = work_package, linked_state) do
    inherited_items = Map.get(linked_state, :attention_items, [])

    maybe_idle_slice_attention =
      if planned_slice.status in ["planned", "approved"] and linked_package_started_while_slice_idle?(linked_state) do
        [
          %{
            key: "linked_package_started_while_slice_idle",
            label: "Linked Package Started",
            tone: "warning",
            reason: "Linked WorkPackage #{work_package.id} has operational state #{linked_state.key} while slice status is #{planned_slice.status}."
          }
        ]
      else
        []
      end

    inherited_items ++ maybe_idle_slice_attention
  end

  defp promoted_linked_operational_state?(%{key: key}) do
    key in [
      "blocked",
      "active",
      "prepared",
      "needs_attention",
      "started_paused",
      "reviewing",
      "ci_waiting",
      "merge_ready",
      "ready_to_finish",
      "merging",
      "merged",
      "closed",
      "abandoned"
    ]
  end

  defp promoted_linked_operational_state?(_state), do: false

  defp linked_package_started_while_slice_idle?(%{key: "prepared"}), do: false
  defp linked_package_started_while_slice_idle?(linked_state), do: promoted_linked_operational_state?(linked_state)

  defp work_package_attention_items(%WorkPackage{} = work_package, blockers, context) do
    missing_readiness = Map.fetch!(context, :missing_readiness)
    activity = Map.fetch!(context, :activity)
    lineage = Map.fetch!(context, :lineage)

    single_items =
      [
        active_blocker_attention_item(blockers),
        missing_readiness_attention_item(work_package, missing_readiness),
        ready_status_with_activity_attention_item(work_package, activity)
      ]
      |> Enum.reject(&is_nil/1)

    single_items ++ lineage_cleanup_attention_items(lineage)
  end

  defp lineage_cleanup_attention_items(%{cleanup_attention: items}) when is_list(items), do: items
  defp lineage_cleanup_attention_items(_lineage), do: []

  defp active_blocker_attention_item(blockers) do
    case active_blockers(blockers) do
      [] ->
        nil

      active ->
        %{
          key: "active_blocker",
          label: "Active Blocker",
          tone: "critical",
          reason: blocker_detail(length(active)),
          blocker_ids: Enum.map(active, & &1.id)
        }
    end
  end

  defp missing_readiness_attention_item(%WorkPackage{status: status}, missing_readiness) when status in @ready_statuses do
    case missing_readiness do
      [] ->
        nil

      missing ->
        %{
          key: "missing_readiness_evidence",
          label: "Missing Readiness Evidence",
          tone: "warning",
          reason: missing_detail(missing),
          missing: missing
        }
    end
  end

  defp missing_readiness_attention_item(%WorkPackage{}, _missing_readiness), do: nil

  defp ready_status_with_activity_attention_item(%WorkPackage{status: "ready_for_worker"}, activity) do
    if activity.has_started and not activity.has_active_worker do
      %{
        key: "ready_for_worker_with_activity",
        label: "Ready Status With Activity",
        tone: "warning",
        reason: "Raw status is ready_for_worker but worker, runtime, progress, PR, review, or merge activity is recorded."
      }
    end
  end

  defp ready_status_with_activity_attention_item(%WorkPackage{}, _delivery_started), do: nil

  defp active_blockers(blockers), do: Enum.filter(blockers, & &1.active)

  defp work_package_activity(%WorkPackage{status: status} = work_package, progress_events, agent_runs, runtime, metadata, grants) do
    has_active_worker =
      active_worker_grant?(grants) or active_agent_run?(agent_runs) or runtime_current_activity?(runtime)

    {has_prepared_worktree, has_meaningful_progress} = progress_activity(progress_events)

    has_started =
      work_package_started?(
        status,
        has_active_worker,
        agent_runs,
        runtime,
        has_meaningful_progress,
        metadata
      )

    has_activity = has_started or has_prepared_worktree

    %{
      has_started: has_started,
      has_active_worker: has_active_worker,
      has_prepared_worktree: has_prepared_worktree,
      last_activity_at: latest_package_activity_at(work_package, progress_events, agent_runs, grants, has_activity),
      is_stale: has_started and not has_active_worker
    }
  end

  defp work_package_started?(status, has_active_worker, agent_runs, runtime, has_meaningful_progress, metadata) do
    status in @started_package_statuses or
      has_active_worker or
      agent_run_activity?(agent_runs) or
      runtime_activity?(runtime) or
      has_meaningful_progress or
      metadata_activity?(metadata)
  end

  defp latest_package_activity_at(_work_package, _progress_events, _agent_runs, _grants, false), do: nil

  defp latest_package_activity_at(%WorkPackage{} = work_package, progress_events, agent_runs, grants, true) do
    [
      work_package.updated_at,
      latest_progress_datetime(progress_events),
      latest_agent_run_datetime(agent_runs),
      latest_grant_activity_datetime(grants)
    ]
    |> latest_datetime()
    |> timestamp()
  end

  defp latest_progress_datetime(progress_events) do
    progress_events
    |> Enum.map(& &1.created_at)
    |> latest_datetime()
  end

  defp latest_agent_run_datetime(agent_runs) do
    agent_runs
    |> Enum.flat_map(fn %AgentRun{} = run ->
      [run.last_seen_at, run.finished_at, run.started_at, run.updated_at, run.inserted_at]
    end)
    |> latest_datetime()
  end

  defp latest_grant_activity_datetime(grants) do
    grants
    |> Enum.flat_map(fn %AccessGrant{} = grant -> [grant.claimed_at, grant.updated_at, grant.inserted_at] end)
    |> latest_datetime()
  end

  defp latest_datetime(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp active_worker_grant?(grants) do
    Enum.any?(grants, fn
      %AccessGrant{grant_role: "worker"} = grant -> active_grant?(grant)
      _grant -> false
    end)
  end

  defp active_agent_run?(agent_runs) do
    Enum.any?(agent_runs, fn
      %AgentRun{status: status} = run -> status in AgentRun.active_statuses() and not stale_agent_run?(run)
      _run -> false
    end)
  end

  defp agent_run_activity?(agent_runs), do: agent_runs != []

  defp progress_activity(progress_events) do
    Enum.reduce(progress_events, {false, false}, fn %ProgressEvent{} = event, {prepared?, meaningful?} ->
      if prepared_worktree_progress_event?(event) do
        {true, meaningful?}
      else
        {prepared?, true}
      end
    end)
  end

  defp prepared_worktree_progress_event?(%ProgressEvent{status: status, payload: payload}) when is_map(payload) do
    payload_status = map_value(payload, "status")

    map_value(payload, "type") == "worktree_lifecycle" and
      map_value(payload, "source_tool") == "prepare_work_package_worktree" and
      status in @prepared_worktree_statuses and
      (is_nil(payload_status) or payload_status in @prepared_worktree_statuses)
  end

  defp prepared_worktree_progress_event?(%ProgressEvent{}), do: false

  defp runtime_activity?(runtime) do
    Enum.any?([:active_count, :queued_count, :stopped_count, :failed_count, :completed_count, :terminal_count], &(safe_map_get(runtime, &1, 0) > 0))
  end

  defp runtime_current_activity?(runtime) do
    current_count = Map.get(runtime, :active_count, 0) + Map.get(runtime, :queued_count, 0)
    stale_count = Map.get(runtime, :stale_count, 0)

    current_count > stale_count
  end

  defp metadata_activity?(metadata) do
    Enum.any?([:branch, :pr, :review_package, :review_completion], &present_metadata_value?(safe_map_get(metadata, &1)))
  end

  defp review_activity?(metadata) do
    present_metadata_value?(safe_map_get(metadata, :review_completion))
  end

  defp present_metadata_value?(nil), do: false
  defp present_metadata_value?(value) when is_map(value), do: map_size(value) > 0
  defp present_metadata_value?(value) when is_list(value), do: value != []
  defp present_metadata_value?(_value), do: true

  defp pr_merged?(metadata) do
    pr = safe_map_get(metadata, :pr) || safe_map_get(metadata, "pr")

    case pr do
      %{"stale" => true} -> false
      pr -> pr_merged_payload?(pr)
    end
  end

  defp safe_map_get(map, key, default \\ nil) do
    Map.get(map, key, default)
  rescue
    BadMapError -> default
  end

  defp pr_merged_payload?(%{} = pr) do
    merged_value?(map_value(pr, "merged")) or
      merged_value?(map_value(pr, "state")) or
      merged_value?(map_value(pr, "status")) or
      merged_value?(map_value(pr, "conclusion")) or
      merge_state_merged?(map_value(pr, "merge_state"))
  end

  defp pr_merged_payload?(_pr), do: false

  defp merge_state_merged?(%{} = merge_state) do
    merged_value?(map_value(merge_state, "merged")) or
      merged_value?(map_value(merge_state, "state")) or
      merged_value?(map_value(merge_state, "status")) or
      merged_value?(map_value(merge_state, "mergeable_state"))
  end

  defp merge_state_merged?(_merge_state), do: false

  defp map_value(%{} = map, key) when is_binary(key), do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp merged_value?(true), do: true

  defp merged_value?(value) when is_binary(value) do
    value |> String.trim() |> String.downcase() |> then(&(&1 in ["merged", "true"]))
  end

  defp merged_value?(_value), do: false

  defp open_package_status?(status), do: status not in @merged_package_statuses and status not in @closed_package_statuses

  defp operational_state(key, label, tone, reason, raw_status, attention_items \\ []) do
    %{
      key: key,
      label: label,
      tone: tone,
      reason: reason,
      raw_status: raw_status,
      attention_items: attention_items
    }
  end

  defp blocker_indicator(%WorkPackage{status: "blocked"}, blockers) do
    active_count = Enum.count(blockers, & &1.active)
    alert_indicator("blocker", "Blocked", "critical", active_count > 0, blocker_detail(active_count))
  end

  defp blocker_indicator(%WorkPackage{}, blockers) do
    active_count = Enum.count(blockers, & &1.active)
    alert_indicator("blocker", "Blockers", "critical", active_count > 0, blocker_detail(active_count))
  end

  defp blocker_detail(1), do: "1 active blocker"
  defp blocker_detail(count), do: "#{count} active blockers"

  defp stale_heartbeat_indicator(%{stale_count: stale_count, stale_heartbeat_after_seconds: threshold}) do
    alert_indicator(
      "stale_heartbeat",
      "Stale heartbeat",
      "warning",
      stale_count > 0,
      "#{stale_count} run(s) past #{threshold}s"
    )
  end

  defp failed_run_indicator(%{failed_count: failed_count}) do
    alert_indicator("failed_run", "Failed runs", "warning", failed_count > 0, "#{failed_count} failed run(s)")
  end

  defp missing_readiness_indicator(%{work_package: %WorkPackage{status: status}} = context) when status in @ready_statuses do
    reasons = readiness_failure_reasons(context)
    missing = missing_readiness_gates(reasons)

    alert_indicator(
      "missing_readiness_evidence",
      "Missing readiness evidence",
      "warning",
      missing != [],
      missing_detail(missing),
      %{missing: missing, reasons: reasons}
    )
  end

  defp missing_readiness_indicator(_context) do
    alert_indicator("missing_readiness_evidence", "Missing readiness evidence", "info", false, "Package is not in a ready state", %{missing: [], reasons: []})
  end

  defp scope_drift_indicator(%{work_package: %WorkPackage{} = work_package, progress_events: progress_events}) do
    reasons = ScopeGuard.failure_reasons(work_package, progress_events)
    drift_reasons = Enum.filter(reasons, &scope_drift_reason?/1)
    blocked_reasons = Enum.filter(reasons, &scope_guard_blocked_reason?/1)
    active_reasons = drift_reasons ++ blocked_reasons
    active? = active_reasons != []

    detail =
      cond do
        drift_reasons != [] -> missing_detail(Enum.map(drift_reasons, &Map.get(&1, "code", @scope_guard_gate)))
        blocked_reasons != [] -> "Scope guard evidence unavailable: " <> missing_detail(Enum.map(blocked_reasons, &Map.get(&1, "code", @scope_guard_gate)))
        reasons != [] -> "Scope guard is awaiting required PR metadata"
        true -> "Scope guard satisfied or not required"
      end

    severity =
      cond do
        drift_reasons != [] -> "critical"
        blocked_reasons != [] -> "warning"
        true -> "info"
      end

    alert_indicator("scope_drift", "Scope guard", severity, active?, detail, %{
      placeholder: false,
      reasons: reasons
    })
  end

  defp scope_drift_reason?(%{"code" => code}) do
    code in [
      "wrong_base_branch",
      "out_of_scope_files",
      "scope_constraints_missing",
      "overbroad_scope_constraints",
      "invalid_changed_file_paths"
    ]
  end

  defp scope_drift_reason?(_reason), do: false

  defp scope_guard_blocked_reason?(%{"code" => "changed_files_unavailable"}), do: true
  defp scope_guard_blocked_reason?(_reason), do: false

  defp alert_indicator(type, label, severity, active, detail, extra \\ %{}) do
    Map.merge(%{type: type, label: label, severity: severity, active: active, detail: detail}, extra)
  end

  defp missing_detail([]), do: "No missing evidence detected"
  defp missing_detail(missing), do: Enum.join(missing, ", ")

  defp missing_readiness_gates(reasons) do
    reasons
    |> Enum.map(&Map.fetch!(&1, "gate"))
    |> Enum.uniq()
  end

  defp readiness_failure_reasons(%{work_package: %WorkPackage{}} = context) do
    [
      {active_blocker?(context.progress_events), "no_active_blockers"},
      {incomplete_plan?(context), "plan_complete"},
      {acceptance_missing?(context), "acceptance_criteria_met"},
      {tests_missing?(context), "tests_passed"},
      {merge_metadata_missing?(context, "branch"), "branch_attached"},
      {merge_metadata_missing?(context, "pr"), "pr_attached"},
      {current_pr_state_missing?(context), "current_pr_state"},
      {ScopeGuard.missing?(context.work_package, context.progress_events), @scope_guard_gate},
      {review_artifacts_missing?(context), "review_artifacts_attached"},
      {review_current_head_missing?(context), "review_current_head"},
      {review_completion_missing?(context), "review_complete"},
      {investigation_findings_missing?(context), "findings_documented"},
      {investigation_recommendation_missing?(context), "recommendation_artifact_recorded"}
    ]
    |> Enum.flat_map(fn
      {true, @scope_guard_gate} -> ScopeGuard.failure_reasons(context.work_package, context.progress_events)
      {true, gate} -> [readiness_failure_reason(gate)]
      {false, _gate} -> []
    end)
  end

  defp readiness_failure_reason(gate) do
    %{
      "gate" => gate,
      "code" => gate,
      "message" => readiness_failure_message(gate)
    }
  end

  defp readiness_failure_message("no_active_blockers"), do: "Active blockers must be resolved before readiness."
  defp readiness_failure_message("plan_complete"), do: "Package plan is missing or still has pending items."
  defp readiness_failure_message("acceptance_criteria_met"), do: "Acceptance criteria evidence is missing."
  defp readiness_failure_message("tests_passed"), do: "Focused test evidence is missing."
  defp readiness_failure_message("branch_attached"), do: "Current branch metadata is missing."
  defp readiness_failure_message("pr_attached"), do: "Current PR metadata is missing."
  defp readiness_failure_message("current_pr_state"), do: "Current synced PR state is missing."
  defp readiness_failure_message("review_artifacts_attached"), do: "Current-head validation artifacts are missing."
  defp readiness_failure_message("review_current_head"), do: "Required review is waiting for an attached exact head."
  defp readiness_failure_message("review_complete"), do: "Required review is not completed for the current exact head and requirement."
  defp readiness_failure_message("findings_documented"), do: "Investigation findings are missing."
  defp readiness_failure_message("recommendation_artifact_recorded"), do: "Investigation recommendation artifact is missing."
  defp readiness_failure_message(_gate), do: "Readiness gate is not satisfied."

  defp merge_metadata_missing?(context, "pr") do
    merge_required?(context.work_package) and pr_required?(context.work_package) and
      not metadata_present?(context.progress_events, "pr", latest_current_head_sha(context.progress_events))
  end

  defp merge_metadata_missing?(context, "branch") do
    merge_required?(context.work_package) and
      not metadata_present?(context.progress_events, "branch", latest_current_head_sha(context.progress_events))
  end

  defp merge_metadata_missing?(context, type) do
    merge_required?(context.work_package) and
      not metadata_present?(context.progress_events, type, latest_current_head_sha(context.progress_events))
  end

  defp current_pr_state_missing?(context) do
    merge_required?(context.work_package) and pr_required?(context.work_package) and
      required_gate?(context.work_package, "current_pr_state") and
      not current_pr_state_present?(context.progress_events, latest_current_head_sha(context.progress_events))
  end

  defp review_current_head_missing?(context) do
    not is_nil(review_requirement(context)) and is_nil(latest_current_head_sha(context.progress_events))
  end

  defp review_completion_missing?(context) do
    case {review_requirement(context), latest_current_head_sha(context.progress_events)} do
      {nil, _head_sha} ->
        false

      {_requirement, nil} ->
        true

      {requirement, head_sha} ->
        not MetadataProjection.review_completion_present?(
          context.progress_events,
          context.work_package.id,
          head_sha,
          requirement
        )
    end
  end

  defp review_requirement(context), do: Map.get(context, :review_requirement, context.work_package.review_requirement)

  defp review_artifacts_missing?(context) do
    merge_required?(context.work_package) and not current_review_artifacts_present?(context)
  end

  defp current_review_artifacts_present?(context) do
    current_head_sha = latest_current_head_sha(context.progress_events)

    case latest_review_package_event(context.progress_events, current_head_sha) do
      %ProgressEvent{payload: payload} when is_map(payload) ->
        artifacts = Map.get(payload, "artifacts")

        is_list(artifacts) and artifacts != [] and
          Enum.all?(artifacts, fn path ->
            is_binary(path) and String.trim(path) != "" and
              MetadataProjection.persisted_review_artifact?(context.artifacts, context.work_package.id, current_head_sha, path)
          end)

      _event ->
        false
    end
  end

  defp investigation_findings_missing?(context), do: context.work_package.kind == "investigation" and context.findings == []

  defp investigation_recommendation_missing?(context) do
    context.work_package.kind == "investigation" and
      not recommendation_artifact_recorded?(context.artifacts, context.work_package.id)
  end

  defp incomplete_plan?(context) do
    plan_required?(context.work_package) and
      (Enum.any?(context.plan_nodes, &(&1.status not in @complete_plan_statuses)) or missing_meaningful_plan?(context))
  end

  defp missing_meaningful_plan?(%{plan_nodes: []}), do: true
  defp missing_meaningful_plan?(_context), do: false

  defp acceptance_missing?(context) do
    required_gate?(context.work_package, "package_acceptance") and not acceptance_recorded?(context)
  end

  defp tests_missing?(context) do
    required_gate?(context.work_package, "focused_tests") and not tests_recorded?(context)
  end

  defp active_blocker?(progress_events) do
    progress_events
    |> Enum.filter(&blocker_event?/1)
    |> Enum.reduce(%{}, fn event, active_by_id ->
      Map.put(active_by_id, blocker_id(event), Map.get(event.payload || %{}, "active") == true)
    end)
    |> Map.values()
    |> Enum.any?(& &1)
  end

  defp blocker_id(%ProgressEvent{payload: payload, idempotency_key: idempotency_key, id: id}) do
    normalize_blocker_id(Map.get(payload || %{}, "blocker_id") || idempotency_key || id)
  end

  defp plan_required?(%WorkPackage{} = work_package) do
    case policy_for(work_package) do
      {:ok, policy} -> get_in(policy, [:constraints, :planning_depth]) == "package"
      {:error, _reason} -> true
    end
  end

  @spec required_gate?(WorkPackage.t(), String.t()) :: boolean()
  def required_gate?(%WorkPackage{} = work_package, gate) do
    case policy_for(work_package) do
      {:ok, policy} -> gate in Map.get(policy, :required_gates, [])
      {:error, _reason} -> false
    end
  end

  defp policy_for(%WorkPackage{} = work_package), do: LifecycleService.policy_for(work_package)

  @spec merge_required?(WorkPackage.t()) :: boolean()
  def merge_required?(%WorkPackage{} = work_package) do
    case policy_for(work_package) do
      {:ok, policy} ->
        required_gates = Map.get(policy, :required_gates, [])
        Enum.any?(@merge_required_gates, &(&1 in required_gates))

      {:error, _reason} ->
        work_package.kind in @runtime_merge_required_kinds
    end
  end

  @spec pr_required?(WorkPackage.t()) :: boolean()
  def pr_required?(%WorkPackage{} = work_package) do
    case policy_for(work_package) do
      {:ok, policy} -> "human_merge" in Map.get(policy, :required_gates, [])
      {:error, _reason} -> work_package.kind in @runtime_merge_required_kinds
    end
  end

  defp acceptance_recorded?(context) do
    progress_events = progress_events_for_review_payload(context)

    if merge_required?(context.work_package) do
      review_package_acceptance_recorded?(progress_events, review_head_sha_for_readiness(context))
    else
      review_package_acceptance_recorded?(progress_events, review_head_sha_for_readiness(context)) or
        current_branch_acceptance_recorded?(progress_events)
    end
  end

  defp review_package_acceptance_recorded?(progress_events, readiness_head_sha) do
    case latest_review_package_event(progress_events, readiness_head_sha) do
      %ProgressEvent{payload: payload} when is_map(payload) -> Map.get(payload, "acceptance_criteria_met") == true
      _event -> false
    end
  end

  defp current_branch_acceptance_recorded?(progress_events) do
    progress_events
    |> Enum.reverse()
    |> Enum.any?(fn
      %ProgressEvent{payload: payload} = event when is_map(payload) ->
        payload_type?(event, "review_package", "submit_review_package") and Map.get(payload, "acceptance_criteria_met") == true

      %ProgressEvent{} ->
        false
    end)
  end

  defp tests_recorded?(context) do
    if merge_required?(context.work_package) do
      review_package_tests_recorded?(context.progress_events, review_head_sha_for_readiness(context))
    else
      progress_events = current_branch_progress_events(context.progress_events)

      review_package_tests_recorded?(progress_events, review_head_sha_for_readiness(context)) or
        progress_status_recorded?(progress_events, "tests_passed")
    end
  end

  defp review_package_tests_recorded?(progress_events, readiness_head_sha) do
    case latest_review_package_event(progress_events, readiness_head_sha) do
      %ProgressEvent{payload: payload} when is_map(payload) ->
        case Map.get(payload, "tests") do
          tests when is_list(tests) -> Enum.any?(tests, &(is_binary(&1) and String.trim(&1) != ""))
          _tests -> false
        end

      _event ->
        false
    end
  end

  defp progress_status_recorded?(progress_events, expected_status) do
    latest_generic_progress_status(progress_events, [expected_status, failed_status(expected_status)]) ==
      expected_status
  end

  defp current_branch_progress_events(progress_events) do
    case latest_branch_event_index(progress_events) do
      nil -> progress_events
      index -> Enum.drop(progress_events, index + 1)
    end
  end

  defp latest_branch_event_index(progress_events) do
    progress_events
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%ProgressEvent{} = event, index} ->
        if payload_type?(event, "branch", "attach_branch"), do: index

      _entry ->
        nil
    end)
  end

  defp latest_generic_progress_status(progress_events, statuses) do
    statuses = MapSet.new(statuses)

    progress_events
    |> Enum.reverse()
    |> Enum.find_value(fn
      %ProgressEvent{status: status} = event ->
        status = normalized_status(status)
        if generic_append_progress_event?(event) and MapSet.member?(statuses, status), do: status

      _event ->
        nil
    end)
  end

  defp generic_append_progress_event?(%ProgressEvent{payload: payload}) when is_map(payload), do: Map.get(payload, "source_tool") == nil
  defp generic_append_progress_event?(%ProgressEvent{payload: nil}), do: true
  defp generic_append_progress_event?(%ProgressEvent{}), do: false

  defp failed_status("tests_passed"), do: "tests_failed"
  defp failed_status(status), do: status <> "_failed"

  defp latest_review_package_event(progress_events, readiness_head_sha) do
    progress_events
    |> current_head_review_package_events(readiness_head_sha)
    |> List.last()
  end

  defp current_head_review_package_events(progress_events, readiness_head_sha) do
    Enum.filter(progress_events, fn event ->
      payload_type?(event, "review_package", "submit_review_package") and review_head_matches?(event.payload, readiness_head_sha)
    end)
  end

  defp review_head_sha_for_readiness(context) do
    current_head_sha = latest_current_head_sha(context.progress_events)

    cond do
      is_binary(current_head_sha) -> current_head_sha
      merge_required?(context.work_package) -> nil
      true -> :any_head
    end
  end

  defp progress_events_for_review_payload(context) do
    if merge_required?(context.work_package) do
      context.progress_events
    else
      current_branch_progress_events(context.progress_events)
    end
  end

  defp status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_label(status), do: to_string(status)

  defp active_grant?(%AccessGrant{revoked_at: %DateTime{}}), do: false

  defp active_grant?(%AccessGrant{expires_at: %DateTime{} = expires_at} = grant) do
    DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) == :gt and claimed_grant?(grant)
  end

  defp active_grant?(%AccessGrant{} = grant), do: claimed_grant?(grant)

  defp claimed_grant?(%AccessGrant{claimed_at: nil}), do: false
  defp claimed_grant?(%AccessGrant{claimed_by: nil}), do: false
  defp claimed_grant?(%AccessGrant{}), do: true

  defp normalize_blocker_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_blocker_id(value), do: to_string(value)

  defp recommendation_artifact_recorded?(artifacts, work_package_id), do: MetadataProjection.recommendation_artifact_recorded?(artifacts, work_package_id)
  defp filled_string?(value), do: MetadataProjection.filled_string?(value)
  defp review_head_matches?(payload, readiness_head_sha), do: MetadataProjection.review_head_matches?(payload, readiness_head_sha)
  defp latest_current_head_sha(progress_events), do: MetadataProjection.latest_current_head_sha(progress_events)
  defp metadata_present?(progress_events, type, head_sha), do: MetadataProjection.metadata_present?(progress_events, type, head_sha)
  defp current_pr_state_present?(progress_events, head_sha), do: MetadataProjection.current_pr_state_present?(progress_events, head_sha)
  defp normalized_status(status), do: MetadataProjection.normalized_status(status)
  defp chronological_progress_events(progress_events), do: MetadataProjection.chronological_progress_events(progress_events)
  defp payload_type?(event, type, source_tool), do: MetadataProjection.payload_type?(event, type, source_tool)
  defp blocker_event?(event), do: BlockerProjection.blocker_event?(event)
  defp redacted_text(value), do: Sanitizer.redacted_text(value)
  defp timestamp(value), do: Sanitizer.timestamp(value)
end
