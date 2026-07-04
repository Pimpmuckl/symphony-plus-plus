defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.AgentRun
  alias SymphonyElixir.SymphonyPlusPlus.AgentRuns.Repository, as: AgentRunRepository
  alias SymphonyElixir.SymphonyPlusPlus.Comments.Repository, as: CommentRepository

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.{
    BlockerProjection,
    CommentProjection,
    DeliverySliceProjection,
    MetadataProjection,
    Sanitizer,
    WorkRequestDetails
  }

  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Repository, as: GuidanceRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.Lifecycle.Service, as: LifecycleService
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ReviewLanes
  alias SymphonyElixir.SymphonyPlusPlus.Readiness.ScopeGuard
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.ReviewProfiles
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Normalization, as: SoloSessionNormalization
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service, as: SoloSessionsService
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Completion, as: WorkRequestCompletion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @stale_heartbeat_after_seconds 300
  @ready_statuses ["ready_for_merge", "ready_for_human_merge", "ready_for_architect_merge"]
  @complete_plan_statuses ["done", "completed", "skipped"]
  @merge_required_gates ["human_merge", "architect_merge"]
  @runtime_merge_required_kinds ["hotfix", "adapter", "mcp", "skill", "hooks", "phase_child"]
  @started_package_statuses ["claimed", "planning", "implementing"]
  @prepared_worktree_statuses ["prepared", "already_prepared"]
  @work_request_slice_state_priority [
    "blocked",
    "active",
    "needs_attention",
    "started_paused",
    "reviewing",
    "ci_waiting",
    "merge_ready",
    "ready_to_finish",
    "ready_for_merge",
    "ready_for_human_merge",
    "merging",
    "needs_closeout",
    "prepared",
    "ready_for_worker",
    "planned",
    "merged",
    "delivered",
    "completed_no_pr",
    "closed",
    "superseded",
    "abandoned",
    "skipped"
  ]
  @delivery_promotion_blocking_work_request_statuses ["human_info_needed", "ready_for_clarification", "clarifying"]
  @merged_package_statuses ["merged", "merged_into_phase"]
  @closed_package_statuses ["closed", "abandoned"]
  @scope_guard_gate "scope_guard"
  @dropped_child_statuses ["abandoned"]
  @non_open_child_statuses ["merged_into_phase", "closed", "abandoned"]
  @work_request_count_chunk_size 500
  @work_package_context_chunk_size 500
  @solo_session_query_chunk_size 500
  @solo_session_snippet_limit 120
  @operator_finished_work_package_limit 80
  @finished_work_package_candidate_multiplier 3
  @finished_work_package_min_candidate_limit 40
  @finished_progress_lookup_chunk_size 500
  @finished_package_statuses ["merged", "merged_into_phase", "closed", "abandoned"]

  @type repo :: module()
  @type dashboard_error :: :not_found | :forbidden | :database_busy | {:storage_failed, String.t()} | term()

  @spec board(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def board(repo) when is_atom(repo) do
    board(repo, [])
  end

  @spec board(repo(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def board(repo, opts) when is_atom(repo) and is_list(opts) do
    safe_read(fn -> build_board(repo, opts) end)
  end

  @spec operator_board(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def operator_board(repo) when is_atom(repo) do
    operator_board(repo, [])
  end

  @spec operator_board(repo(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def operator_board(repo, opts) when is_atom(repo) and is_list(opts) do
    safe_read(fn ->
      opts
      |> Keyword.put(:active_blocking_edges?, true)
      |> Keyword.put_new(:finished_work_package_limit, @operator_finished_work_package_limit)
      |> then(&build_board(repo, &1))
    end)
  end

  @spec repo_identity_catalog(repo()) :: {:ok, RepoIdentity.catalog()} | {:error, dashboard_error()}
  def repo_identity_catalog(repo) when is_atom(repo) do
    safe_read(fn ->
      {:ok,
       repo
       |> repo_identity_repo_values()
       |> build_repo_identity_catalog()}
    end)
  end

  @spec local_operator_repo_identity_catalog(repo()) :: {:ok, RepoIdentity.catalog()} | {:error, dashboard_error()}
  def local_operator_repo_identity_catalog(repo) when is_atom(repo) do
    safe_read(fn ->
      {:ok,
       repo
       |> repo_identity_repo_values()
       |> build_repo_identity_catalog(local_operator_trusted_repo_remotes(), local_path_remotes?: true)}
    end)
  end

  @spec phase_board(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def phase_board(repo, phase_id) when is_atom(repo) and is_binary(phase_id) do
    phase_board(repo, phase_id, [])
  end

  @spec phase_board(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def phase_board(repo, phase_id, filters) when is_atom(repo) and is_binary(phase_id) and is_list(filters) do
    safe_read(fn -> build_phase_board(repo, phase_id, filters) end)
  end

  @spec phase_board_for_grant(repo(), String.t(), AccessGrant.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def phase_board_for_grant(repo, phase_id, %AccessGrant{} = grant) when is_atom(repo) and is_binary(phase_id) do
    with {:ok, filters} <- phase_board_filters_for_grant(grant) do
      phase_board(repo, phase_id, filters)
    end
  end

  @spec work_requests_for_grant(repo(), AccessGrant.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_requests_for_grant(repo, %AccessGrant{} = grant) when is_atom(repo) do
    work_requests_for_grant(repo, grant, [])
  end

  @spec work_requests_for_grant(repo(), AccessGrant.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_requests_for_grant(repo, %AccessGrant{} = grant, opts) when is_atom(repo) and is_list(opts) do
    safe_read(fn ->
      with {:ok, filters} <- work_request_filters_for_grant(repo, grant),
           {:ok, work_requests} <- WorkRequestRepository.list(repo, filters |> Map.new() |> Map.put(:include_archived, true)),
           repo_identity_catalog = repo_identity_catalog_from_opts(opts, Enum.map(work_requests, & &1.repo)),
           {:ok, cards} <- work_request_cards(repo, ordered_work_requests(work_requests), Keyword.merge(opts, grant: grant, repo_identity_catalog: repo_identity_catalog)) do
        cards = visible_work_request_cards(cards)

        {:ok,
         %{
           work_requests: cards,
           total_count: length(cards)
         }}
      end
    end)
  end

  @spec work_requests(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_requests(repo) when is_atom(repo) do
    work_requests(repo, [])
  end

  @spec work_requests(repo(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_requests(repo, opts) when is_atom(repo) and is_list(opts) do
    safe_read(fn ->
      with {:ok, work_requests} <- WorkRequestRepository.list(repo, %{include_archived: true}),
           {:ok, repo_identity_catalog} <- repo_identity_catalog_from_repo(repo, opts, Enum.map(work_requests, & &1.repo)),
           {:ok, cards} <- work_request_cards(repo, ordered_work_requests(work_requests), Keyword.put(opts, :repo_identity_catalog, repo_identity_catalog)) do
        cards = visible_work_request_cards(cards)

        {:ok,
         %{
           work_requests: cards,
           total_count: length(cards)
         }}
      end
    end)
  end

  @spec archived_work_requests(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def archived_work_requests(repo) when is_atom(repo) do
    archived_work_requests(repo, [])
  end

  @spec archived_work_requests(repo(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def archived_work_requests(repo, opts) when is_atom(repo) and is_list(opts) do
    safe_read(fn ->
      with {:ok, work_requests} <- WorkRequestRepository.list(repo, %{include_archived: true}),
           archived_work_requests = Enum.filter(work_requests, &(not is_nil(&1.archived_at))),
           {:ok, repo_identity_catalog} <-
             repo_identity_catalog_from_repo(repo, opts, Enum.map(archived_work_requests, & &1.repo)),
           {:ok, cards} <-
             work_request_cards(
               repo,
               ordered_work_requests(archived_work_requests),
               Keyword.put(opts, :repo_identity_catalog, repo_identity_catalog)
             ) do
        cards = Enum.filter(cards, &(not is_nil(&1.archived_at)))

        {:ok,
         %{
           work_requests: cards,
           total_count: length(cards)
         }}
      end
    end)
  end

  @spec human_guidance_requests(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  def human_guidance_requests(repo) when is_atom(repo) do
    human_guidance_requests(repo, [])
  end

  @spec human_guidance_requests(repo(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def human_guidance_requests(repo, opts) when is_atom(repo) and is_list(opts) do
    safe_read(fn ->
      with {:ok, cards} <- human_guidance_request_cards(repo, opts) do
        {:ok,
         %{
           guidance_requests: cards,
           total_count: length(cards)
         }}
      end
    end)
  end

  @spec solo_sessions(repo()) :: {:ok, map()} | {:error, dashboard_error()}
  @spec solo_sessions(repo(), map()) :: {:ok, map()} | {:error, dashboard_error()}
  def solo_sessions(repo, filters \\ %{}) when is_atom(repo) and is_map(filters) do
    solo_sessions(repo, filters, [])
  end

  @spec solo_sessions(repo(), map(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def solo_sessions(repo, filters, opts) when is_atom(repo) and is_map(filters) and is_list(opts) do
    safe_read(fn ->
      with {:ok, sessions} <- SoloSessionsService.list(repo, filters),
           {:ok, repo_identity_catalog} <- repo_identity_catalog_from_repo(repo, opts, Enum.map(sessions, & &1.repo)),
           {:ok, cards} <- solo_session_cards(repo, sessions, repo_identity_catalog) do
        {:ok,
         %{
           solo_sessions: cards,
           total_count: length(cards)
         }}
      end
    end)
  end

  @spec solo_session_detail(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def solo_session_detail(repo, solo_session_id) when is_atom(repo) and is_binary(solo_session_id) do
    solo_session_detail(repo, solo_session_id, [])
  end

  @spec solo_session_detail(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def solo_session_detail(repo, solo_session_id, opts) when is_atom(repo) and is_binary(solo_session_id) and is_list(opts) do
    safe_read(fn ->
      with {:ok, session} <- SoloSessionsService.get(repo, solo_session_id),
           {:ok, entries} <- SoloSessionsService.list_entries(repo, solo_session_id) do
        repo_identity_catalog = repo_identity_catalog_from_opts(opts, [session.repo])

        {:ok,
         %{
           solo_session: solo_session_payload(session, repo_identity_catalog),
           entries: Enum.map(entries, &solo_session_detail_entry/1),
           entry_count: length(entries)
         }}
      end
    end)
  end

  @spec solo_session_repos(repo()) :: {:ok, [String.t()]} | {:error, dashboard_error()}
  def solo_session_repos(repo) when is_atom(repo) do
    safe_read(fn ->
      repos =
        repo.all(
          from(session in SoloSession,
            where: not is_nil(session.repo) and session.repo != "",
            distinct: true,
            order_by: [asc: session.repo],
            select: session.repo
          )
        )

      {:ok, repos}
    end)
  end

  @spec solo_session_streams(repo()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def solo_session_streams(repo) when is_atom(repo) do
    solo_session_streams(repo, [])
  end

  @spec solo_session_streams(repo(), keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def solo_session_streams(repo, opts) when is_atom(repo) and is_list(opts) do
    safe_read(fn ->
      raw_streams =
        repo.all(
          from(session in SoloSession,
            where: not is_nil(session.repo) and session.repo != "",
            where: not is_nil(session.base_branch) and session.base_branch != "",
            group_by: [session.repo, session.base_branch],
            order_by: [asc: session.repo, asc: session.base_branch],
            select: %{
              repo: session.repo,
              base_branch: session.base_branch,
              solo_session_count: count(session.id)
            }
          )
        )

      with {:ok, repo_identity_catalog} <- repo_identity_catalog_from_repo(repo, opts, Enum.map(raw_streams, & &1.repo)) do
        {:ok, canonical_solo_session_streams(raw_streams, repo_identity_catalog)}
      end
    end)
  end

  @spec solo_session_count(repo()) :: {:ok, non_neg_integer()} | {:error, dashboard_error()}
  def solo_session_count(repo) when is_atom(repo) do
    safe_read(fn ->
      count =
        repo.one(
          from(session in SoloSession,
            select: count(session.id)
          )
        )

      {:ok, count || 0}
    end)
  end

  defp canonical_solo_session_streams(streams, repo_identity_catalog) do
    streams
    |> Enum.map(&Map.merge(&1, RepoIdentity.fields(repo_identity_catalog, &1.repo)))
    |> Enum.group_by(&{&1.repo_key || &1.repo, &1.base_branch})
    |> Enum.map(fn {_key, grouped_streams} -> canonical_solo_session_stream(grouped_streams) end)
    |> Enum.sort_by(&{&1.repo_key || &1.repo || "", &1.base_branch || ""})
  end

  defp canonical_solo_session_stream([first | _rest] = streams) do
    %{
      repo: preferred_solo_session_stream_repo(streams),
      repo_key: first.repo_key,
      repo_display: first.repo_display,
      repo_remote: Enum.find_value(streams, & &1.repo_remote),
      repo_aliases: repo_identity_aliases(streams),
      base_branch: first.base_branch,
      solo_session_count: Enum.sum(Enum.map(streams, & &1.solo_session_count))
    }
  end

  defp preferred_solo_session_stream_repo(streams) do
    streams
    |> Enum.map(& &1.repo)
    |> Enum.uniq()
    |> Enum.sort_by(&{String.contains?(&1, "/"), String.downcase(&1)})
    |> hd()
  end

  defp repo_identity_aliases(items) do
    items
    |> Enum.flat_map(&Map.get(&1, :repo_aliases, []))
    |> Enum.uniq()
    |> Enum.sort_by(&String.downcase/1)
  end

  defp put_repo_identity_fields(payload, repo_identity_catalog, repo_value) when is_map(payload) do
    Map.merge(payload, RepoIdentity.fields(repo_identity_catalog, repo_value))
  end

  @spec work_request_detail_for_grant(repo(), String.t(), AccessGrant.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_request_detail_for_grant(repo, work_request_id, %AccessGrant{} = grant)
      when is_atom(repo) and is_binary(work_request_id) do
    work_request_detail_for_grant(repo, work_request_id, grant, [])
  end

  @spec work_request_detail_for_grant(repo(), String.t(), AccessGrant.t(), keyword()) ::
          {:ok, map()} | {:error, dashboard_error()}
  def work_request_detail_for_grant(repo, work_request_id, %AccessGrant{} = grant, opts)
      when is_atom(repo) and is_binary(work_request_id) and is_list(opts) do
    safe_read(fn ->
      with {:ok, work_request} <- WorkRequestRepository.get(repo, work_request_id),
           :ok <- require_visible_work_request_scope(repo, work_request, grant),
           {:ok, questions} <- WorkRequestRepository.list_questions(repo, work_request_id),
           {:ok, decisions} <- WorkRequestRepository.list_decisions(repo, work_request_id),
           {:ok, planned_slices} <- WorkRequestRepository.list_planned_slices(repo, work_request_id),
           {:ok, work_package_contexts} <- planned_slice_work_package_contexts_for_grant(repo, planned_slices, grant),
           delivery_board_opts = delivery_board_opts(work_request, planned_slices, work_package_contexts, opts),
           {:ok, delivery_board} <- DeliveryBoard.project(repo, work_request_id, delivery_board_opts),
           visible_planned_slices = visible_planned_slices(planned_slices, delivery_board),
           {:ok, comment_context} <- work_request_comment_context(repo, work_request, planned_slices),
           {:ok, repo_identity_catalog} <-
             work_request_detail_repo_identity_catalog_for_grant(repo, grant, [work_request.repo]) do
        all_planned_slices = ordered_sequence_records(planned_slices)
        questions = ordered_sequence_records(questions)
        decisions = ordered_sequence_records(decisions)
        planned_slices = ordered_sequence_records(visible_planned_slices)

        work_request_payload =
          work_request_payload(
            work_request,
            questions,
            planned_slices,
            work_package_contexts,
            repo_identity_catalog,
            comment_context,
            delivery_board: delivery_board,
            delivery_state_opts: [include_package_fields?: false],
            comment_planned_slices: all_planned_slices
          )

        planned_slice_payloads =
          planned_slice_payloads(planned_slices, %{}, false, comment_context, delivery_board: delivery_board)

        {:ok,
         %{
           work_request: work_request_payload,
           clarification_questions: Enum.map(questions, &clarification_question/1),
           decision_logs: Enum.map(decisions, &decision_log_entry/1),
           planned_slices: planned_slice_payloads,
           product_tree:
             ProductTree.project(repo, work_request.id, planned_slice_payloads,
               visible_only?: true,
               include_unlinked_nodes?: true
             ),
           comments: CommentProjection.comments_for(comment_context, "work_request", work_request.id),
           summary: work_request_summary(questions, decisions, planned_slices, comment_context)
         }}
      end
    end)
  end

  @spec work_request_detail(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_request_detail(repo, work_request_id) when is_atom(repo) and is_binary(work_request_id) do
    work_request_detail(repo, work_request_id, [])
  end

  @spec work_request_detail(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def work_request_detail(repo, work_request_id, opts) when is_atom(repo) and is_binary(work_request_id) and is_list(opts) do
    with {:ok, [detail]} <- work_request_details(repo, [work_request_id], opts) do
      {:ok, detail}
    end
  end

  @spec work_request_board_details(repo(), [String.t()]) :: {:ok, [map()]} | {:error, dashboard_error()}
  def work_request_board_details(repo, work_request_ids) when is_atom(repo) and is_list(work_request_ids) do
    work_request_board_details(repo, work_request_ids, [])
  end

  @spec work_request_board_details(repo(), [String.t()], keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def work_request_board_details(repo, work_request_ids, opts)
      when is_atom(repo) and is_list(work_request_ids) and is_list(opts) do
    safe_read(fn -> WorkRequestDetails.board_details(repo, work_request_ids, opts) end)
  end

  @spec work_request_details(repo(), [String.t()]) :: {:ok, [map()]} | {:error, dashboard_error()}
  def work_request_details(repo, work_request_ids) when is_atom(repo) and is_list(work_request_ids) do
    work_request_details(repo, work_request_ids, [])
  end

  @spec work_request_details(repo(), [String.t()], keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def work_request_details(repo, work_request_ids, opts)
      when is_atom(repo) and is_list(work_request_ids) and is_list(opts) do
    safe_read(fn -> WorkRequestDetails.details(repo, work_request_ids, opts) end)
  end

  @doc false
  @spec work_requests_in_input_order([String.t()], map()) :: {:ok, [WorkRequest.t()]} | {:error, dashboard_error()}
  def work_requests_in_input_order(work_request_ids, work_requests_by_id) do
    work_request_ids
    |> Enum.reduce_while({:ok, []}, fn work_request_id, {:ok, work_requests} ->
      case Map.fetch(work_requests_by_id, work_request_id) do
        {:ok, %WorkRequest{} = work_request} -> {:cont, {:ok, [work_request | work_requests]}}
        :error -> {:halt, {:error, :not_found}}
      end
    end)
    |> case do
      {:ok, work_requests} -> {:ok, Enum.reverse(work_requests)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec all_planned_slices([WorkRequest.t()], map()) :: [PlannedSlice.t()]
  def all_planned_slices(work_requests, planned_slices_by_request) do
    Enum.flat_map(work_requests, &Map.get(planned_slices_by_request, &1.id, []))
  end

  defp delivery_board_opts(%WorkRequest{} = work_request, planned_slices, work_package_contexts, _opts) do
    [
      work_request: work_request,
      planned_slices: planned_slices,
      visible_work_package_ids: Map.keys(work_package_contexts),
      work_package_contexts: work_package_contexts
    ]
  end

  @spec work_request_filters_for_grant(repo(), AccessGrant.t()) :: {:ok, keyword()} | {:error, dashboard_error()}
  def work_request_filters_for_grant(repo, %AccessGrant{} = grant) when is_atom(repo) do
    case phase_board_filters_for_grant(grant) do
      {:ok, []} -> legacy_work_request_filters_for_grant(repo, grant)
      result -> result
    end
  end

  @spec phase_board_filters_for_grant(AccessGrant.t()) :: {:ok, keyword()} | {:error, :forbidden}
  def phase_board_filters_for_grant(%AccessGrant{} = grant) do
    if explicit_phase_architect_grant?(grant) do
      with {:ok, repo} <- frozen_scope_value(grant.scope_repo),
           {:ok, base_branch} <- frozen_scope_value(grant.scope_base_branch) do
        {:ok, repo: repo, base_branch: base_branch}
      else
        {:error, :forbidden} -> {:error, :forbidden}
      end
    else
      {:ok, []}
    end
  end

  @spec require_phase_board_anchor_scope(WorkPackage.t(), AccessGrant.t(), String.t()) :: :ok | {:error, :forbidden}
  def require_phase_board_anchor_scope(%WorkPackage{} = anchor, %AccessGrant{} = grant, phase_id) when is_binary(phase_id) do
    cond do
      anchor.phase_id != phase_id ->
        {:error, :forbidden}

      explicit_phase_architect_grant?(grant) ->
        require_frozen_scope_match(anchor, grant)

      true ->
        :ok
    end
  end

  @spec require_phase_board_work_package_scope(WorkPackage.t(), AccessGrant.t()) :: :ok | {:error, :forbidden}
  def require_phase_board_work_package_scope(%WorkPackage{} = work_package, %AccessGrant{} = grant) do
    with {:ok, filters} <- phase_board_filters_for_grant(grant) do
      if phase_work_package_matches_filters?(work_package, filters) do
        :ok
      else
        {:error, :forbidden}
      end
    end
  end

  @spec detail(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def detail(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    detail(repo, work_package_id, [])
  end

  @spec detail(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def detail(repo, work_package_id, opts) when is_atom(repo) and is_binary(work_package_id) and is_list(opts) do
    safe_read(fn ->
      with {:ok, state} <- planning_state(repo, work_package_id),
           {:ok, grants} <- AccessGrantRepository.list_for_work_package(repo, work_package_id),
           {:ok, agent_runs} <- AgentRunRepository.list_for_work_package(repo, work_package_id),
           {:ok, guidance_requests} <- GuidanceRequestRepository.list_for_work_package(repo, work_package_id),
           {:ok, comment_context} <- comment_context(repo, [{"work_package", work_package_id}]) do
        repo_identity_catalog = repo_identity_catalog_from_opts(opts, [state.work_package.repo])
        blockers = blockers(state.progress_events)
        summary = summary(state, grants, agent_runs, blockers, guidance_requests, comment_context)

        {:ok,
         %{
           work_package:
             state.work_package
             |> work_package_detail(repo_identity_catalog)
             |> CommentProjection.put_counts(CommentProjection.counts_for(comment_context, "work_package", work_package_id)),
           lineage: package_lineage(repo, work_package_id),
           summary: summary,
           comments: CommentProjection.comments_for(comment_context, "work_package", work_package_id),
           plan: Enum.map(state.plan_nodes, &plan_node/1),
           findings: Enum.map(state.findings, &finding/1),
           progress: Enum.map(state.progress_events, &progress_event/1),
           artifacts: Enum.map(state.artifacts, &artifact/1),
           blockers: blockers,
           guidance_requests: Enum.map(guidance_requests, &guidance_request/1),
           grants: Enum.map(grants, &grant/1),
           agent_runs: Enum.map(agent_runs, &agent_run/1),
           metadata: metadata(state.progress_events, state.artifacts, state.work_package.id),
           alert_indicators: alert_indicators(repo, state, summary.runtime)
         }}
      end
    end)
  end

  @spec timeline(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def timeline(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_read(fn ->
      with {:ok, state} <- planning_state(repo, work_package_id) do
        events =
          (Enum.map(state.progress_events, &timeline_progress_event/1) ++ Enum.map(state.findings, &timeline_finding/1))
          |> Enum.sort_by(&timeline_sort_key/1)

        {:ok, %{work_package_id: work_package_id, events: events}}
      end
    end)
  end

  @spec artifacts(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def artifacts(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_read(fn ->
      with {:ok, _work_package} <- WorkPackageRepository.get(repo, work_package_id),
           {:ok, artifacts} <- PlanningRepository.list_artifacts(repo, work_package_id) do
        {:ok, %{work_package_id: work_package_id, artifacts: Enum.map(artifacts, &artifact/1)}}
      end
    end)
  end

  @spec blockers(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def blockers(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_read(fn ->
      with {:ok, state} <- planning_state(repo, work_package_id) do
        {:ok, %{work_package_id: work_package_id, blockers: blockers(state.progress_events)}}
      end
    end)
  end

  @spec grants(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def grants(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_read(fn ->
      with {:ok, _work_package} <- WorkPackageRepository.get(repo, work_package_id),
           {:ok, grants} <- AccessGrantRepository.list_for_work_package(repo, work_package_id) do
        {:ok, %{work_package_id: work_package_id, grants: Enum.map(grants, &grant/1)}}
      end
    end)
  end

  @spec agent_runs(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def agent_runs(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    safe_read(fn ->
      with {:ok, _work_package} <- WorkPackageRepository.get(repo, work_package_id),
           {:ok, agent_runs} <- AgentRunRepository.list_for_work_package(repo, work_package_id) do
        {:ok, %{work_package_id: work_package_id, agent_runs: Enum.map(agent_runs, &agent_run/1)}}
      end
    end)
  end

  @spec card(repo(), WorkPackage.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def card(repo, %WorkPackage{} = work_package) when is_atom(repo) do
    safe_read(fn ->
      with {:ok, context} <- card_context(repo, work_package) do
        {:ok, context.card}
      end
    end)
  end

  defp card_context(repo, %WorkPackage{} = work_package) do
    with {:ok, repo_identity_catalog} <- repo_identity_catalog_from_repo(repo, [], [work_package.repo]) do
      card_context(repo, work_package, package_lineage(repo, work_package.id), repo_identity_catalog)
    end
  end

  defp card_context(repo, %WorkPackage{} = work_package, lineage, repo_identity_catalog) do
    with {:ok, status_summary} <- PlanningRepository.get_status_summary(repo, work_package.id),
         {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package.id),
         {:ok, readiness_collections} <- readiness_collections(repo, work_package),
         {:ok, agent_runs} <- AgentRunRepository.list_for_work_package(repo, work_package.id),
         {:ok, grants} <- AccessGrantRepository.list_for_work_package(repo, work_package.id),
         {:ok, comment_context} <- comment_count_context(repo, [{"work_package", work_package.id}]) do
      %{artifacts: artifacts, findings: findings} = readiness_collections
      blockers = blockers(progress_events)
      runtime = runtime_summary(agent_runs)

      readiness_context =
        readiness_context(
          repo,
          work_package,
          status_summary.plan_nodes,
          progress_events,
          artifacts,
          findings
        )

      metadata = metadata(progress_events, artifacts, work_package.id)

      operational_state =
        work_package_operational_state(work_package, %{
          agent_runs: agent_runs,
          progress_events: progress_events,
          blockers: blockers,
          runtime: runtime,
          metadata: metadata,
          readiness_context: readiness_context,
          grants: grants,
          lineage: lineage
        })

      {:ok,
       %{
         work_package: work_package,
         blockers: blockers,
         card:
           %{
             id: work_package.id,
             title: redacted_text(work_package.title),
             kind: work_package.kind,
             status: work_package.status,
             merge_required: merge_required?(work_package),
             pr_required: pr_required?(work_package),
             repo: work_package.repo,
             base_branch: work_package.base_branch,
             parent_id: work_package.parent_id,
             phase_id: work_package.phase_id,
             owner_id: work_package.owner_id,
             active_agent_run: latest_active_agent_run(agent_runs),
             runtime: runtime,
             latest_progress_at: latest_progress_at(progress_events),
             active_blocker_count: Enum.count(blockers, & &1.active),
             active_blockers: active_blockers(blockers),
             artifact_count: status_summary.artifact_count,
             finding_count: status_summary.finding_count,
             plan: plan_summary(status_summary.plan_nodes),
             metadata: metadata,
             lineage: lineage,
             operational_state: operational_state,
             alert_indicators: alert_indicators(readiness_context, blockers, runtime),
             inserted_at: timestamp(work_package.inserted_at),
             updated_at: timestamp(work_package.updated_at)
           }
           |> CommentProjection.put_counts(CommentProjection.counts_for(comment_context, "work_package", work_package.id))
           |> put_repo_identity_fields(repo_identity_catalog, work_package.repo)
       }}
    end
  end

  defp readiness_collections(repo, %WorkPackage{} = work_package) do
    with {:ok, artifacts} <- readiness_artifacts(repo, work_package),
         {:ok, findings} <- readiness_findings(repo, work_package) do
      {:ok, %{artifacts: artifacts, findings: findings}}
    end
  end

  defp readiness_artifacts(repo, %WorkPackage{status: status} = work_package) when status in @ready_statuses do
    PlanningRepository.list_artifacts(repo, work_package.id)
  end

  defp readiness_artifacts(repo, %WorkPackage{} = work_package) do
    if artifact_backed_readiness_gate_required?(work_package) do
      PlanningRepository.list_artifacts(repo, work_package.id)
    else
      {:ok, []}
    end
  end

  defp artifact_backed_readiness_gate_required?(%WorkPackage{} = work_package) do
    Enum.any?(["recommendation_artifact_recorded", "review_artifacts_attached", "review_suite_result"], &required_gate?(work_package, &1))
  end

  defp readiness_findings(repo, %WorkPackage{status: status, id: work_package_id}) when status in @ready_statuses do
    PlanningRepository.list_findings(repo, work_package_id)
  end

  defp readiness_findings(_repo, %WorkPackage{}), do: {:ok, []}

  @spec work_package_detail(WorkPackage.t()) :: map()
  def work_package_detail(%WorkPackage{} = work_package) do
    work_package_detail(work_package, build_repo_identity_catalog([work_package.repo]))
  end

  @spec work_package_detail(WorkPackage.t(), RepoIdentity.catalog()) :: map()
  def work_package_detail(%WorkPackage{} = work_package, repo_identity_catalog) when is_map(repo_identity_catalog) do
    %{
      id: work_package.id,
      kind: work_package.kind,
      title: redacted_text(work_package.title),
      repo: work_package.repo,
      base_branch: work_package.base_branch,
      branch_pattern: work_package.branch_pattern,
      product_description: redacted_text(work_package.product_description),
      engineering_scope: redacted_text(work_package.engineering_scope),
      allowed_file_globs: work_package.allowed_file_globs || [],
      policy_template: redacted_text(work_package.policy_template),
      acceptance_criteria: Enum.map(work_package.acceptance_criteria || [], &redacted_text/1),
      status: work_package.status,
      parent_id: work_package.parent_id,
      phase_id: work_package.phase_id,
      owner_id: work_package.owner_id,
      inserted_at: timestamp(work_package.inserted_at),
      updated_at: timestamp(work_package.updated_at)
    }
    |> put_repo_identity_fields(repo_identity_catalog, work_package.repo)
  end

  @doc false
  @spec collect_or_error([{:ok, term()} | {:error, term()}]) :: {:ok, [term()]} | {:error, term()}
  def collect_or_error(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, item}, {:ok, items} -> {:cont, {:ok, [item | items]}}
      {:error, reason}, {:ok, _items} -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_board(repo, opts) do
    with {:ok, work_packages} <- WorkPackageRepository.list(repo),
         source_work_packages = board_source_work_packages(work_packages, opts),
         visible_work_packages = board_work_packages(repo, source_work_packages, opts),
         {:ok, repo_identity_catalog} <- repo_identity_catalog_from_repo(repo, opts, Enum.map(visible_work_packages, & &1.repo)),
         {:ok, contexts} <- card_contexts_for_packages(repo, visible_work_packages, repo_identity_catalog) do
      cards = Enum.map(contexts, & &1.card)
      groups = group_cards(cards)

      board = %{
        groups: groups,
        package_limits: package_limits(source_work_packages, visible_work_packages, opts),
        visible_count: length(cards),
        statuses: group_statuses(groups),
        total_count: length(source_work_packages)
      }

      maybe_put_active_blocking_edges(repo, board, contexts, opts)
    end
  end

  defp board_source_work_packages(work_packages, opts) do
    hidden_ids = hidden_work_package_ids(opts)
    Enum.reject(work_packages, &MapSet.member?(hidden_ids, &1.id))
  end

  defp hidden_work_package_ids(opts) do
    case Keyword.get(opts, :hidden_work_package_ids, MapSet.new()) do
      %MapSet{} = ids -> ids
      ids when is_list(ids) -> MapSet.new(ids)
      _ids -> MapSet.new()
    end
  end

  defp board_work_packages(repo, work_packages, opts) do
    case finished_work_package_limit(opts) do
      :all ->
        work_packages

      limit ->
        {finished, active} = Enum.split_with(work_packages, &finished_work_package?/1)
        active ++ visible_finished_work_packages(repo, finished, limit)
    end
  end

  defp package_limits(work_packages, visible_work_packages, opts) do
    finished_total_count = Enum.count(work_packages, &finished_work_package?/1)
    finished_visible_count = Enum.count(visible_work_packages, &finished_work_package?/1)
    limit = finished_work_package_limit(opts)

    %{
      finished_work_packages: %{
        limit: if(limit == :all, do: nil, else: limit),
        shown_count: finished_visible_count,
        total_count: finished_total_count,
        truncated: finished_visible_count < finished_total_count
      }
    }
  end

  defp finished_work_package_limit(opts) do
    case Keyword.get(opts, :finished_work_package_limit, :all) do
      limit when is_integer(limit) and limit >= 0 -> limit
      _limit -> :all
    end
  end

  defp finished_work_package?(%WorkPackage{status: status}), do: status in @finished_package_statuses

  defp visible_finished_work_packages(_repo, _finished, 0), do: []
  defp visible_finished_work_packages(_repo, [], _limit), do: []

  defp visible_finished_work_packages(repo, finished, limit) do
    candidate_limit = finished_work_package_candidate_limit(limit)
    latest_progress_by_id = recent_finished_progress_by_work_package_id(repo, finished, candidate_limit)
    candidates_by_id = Map.new(finished, &{&1.id, &1})

    package_candidate_ids =
      finished
      |> sort_finished_work_packages(%{})
      |> Enum.take(candidate_limit)
      |> Enum.map(& &1.id)

    (package_candidate_ids ++ Map.keys(latest_progress_by_id))
    |> Enum.uniq()
    |> Enum.flat_map(fn id ->
      case Map.fetch(candidates_by_id, id) do
        {:ok, work_package} -> [work_package]
        :error -> []
      end
    end)
    |> sort_finished_work_packages(latest_progress_by_id)
    |> Enum.take(limit)
  end

  defp finished_work_package_candidate_limit(limit), do: max(limit * @finished_work_package_candidate_multiplier, @finished_work_package_min_candidate_limit)

  defp recent_finished_progress_by_work_package_id(repo, finished, limit) do
    finished
    |> Enum.map(& &1.id)
    |> Enum.chunk_every(@finished_progress_lookup_chunk_size)
    |> Enum.flat_map(&recent_finished_progress_rows(repo, &1, limit))
    |> Enum.sort_by(fn {_work_package_id, created_at} -> timestamp_sort_value(created_at) end, :desc)
    |> Enum.take(limit)
    |> Map.new()
  end

  defp recent_finished_progress_rows(repo, work_package_ids, limit) do
    from(progress_event in ProgressEvent,
      where: progress_event.work_package_id in ^work_package_ids,
      group_by: progress_event.work_package_id,
      order_by: [desc: max(progress_event.created_at)],
      limit: ^limit,
      select: {progress_event.work_package_id, max(progress_event.created_at)}
    )
    |> repo.all()
  end

  defp sort_finished_work_packages(work_packages, latest_progress_by_id) do
    Enum.sort_by(work_packages, &recent_work_package_sort_key(&1, latest_progress_by_id), :desc)
  end

  defp recent_work_package_sort_key(%WorkPackage{} = work_package, latest_progress_by_id) do
    {
      timestamp_sort_value(recent_work_package_at(work_package, latest_progress_by_id)),
      timestamp_sort_value(work_package.updated_at),
      timestamp_sort_value(work_package.inserted_at),
      work_package.id || ""
    }
  end

  defp recent_work_package_at(%WorkPackage{} = work_package, latest_progress_by_id) do
    [Map.get(latest_progress_by_id, work_package.id), work_package.updated_at, work_package.inserted_at]
    |> Enum.max_by(&timestamp_sort_value/1, fn -> nil end)
  end

  defp maybe_put_active_blocking_edges(repo, board, contexts, opts) do
    if Keyword.get(opts, :active_blocking_edges?, false) do
      put_active_blocking_edges(repo, board, contexts)
    else
      {:ok, board}
    end
  end

  defp put_active_blocking_edges(repo, board, contexts) do
    with {:ok, active_blocking_edges} <- active_blocking_edges_from_card_contexts(repo, contexts) do
      {:ok, Map.put(board, :active_blocking_edges, active_blocking_edges)}
    end
  end

  defp build_phase_board(repo, phase_id, filters) do
    with {:ok, phase} <- PhaseRepository.get(repo, phase_id),
         {:ok, work_packages} <- WorkPackageRepository.list_for_phase(repo, phase_id),
         summary_work_packages = filter_phase_work_packages(work_packages, phase_scope_filters(filters)),
         scoped_work_packages = filter_phase_work_packages(work_packages, filters),
         repo_identity_catalog = build_repo_identity_catalog(Enum.map(summary_work_packages, & &1.repo)),
         {:ok, cards} <- cards_for_packages(repo, scoped_work_packages, repo_identity_catalog) do
      groups = group_cards(cards)

      {:ok,
       %{
         phase: phase(phase),
         groups: groups,
         statuses: group_statuses(groups),
         total_count: length(cards),
         summary: phase_progress_summary(summary_work_packages)
       }}
    end
  end

  defp phase_progress_summary(work_packages) do
    phase_children = Enum.filter(work_packages, &phase_child_package?/1)
    progress_children = Enum.reject(phase_children, &(&1.status in @dropped_child_statuses))

    %{
      child_count: length(progress_children),
      merged_child_count: Enum.count(progress_children, &(&1.status == "merged_into_phase")),
      ready_child_count: Enum.count(progress_children, &(&1.status == "ready_for_architect_merge")),
      merging_child_count: Enum.count(progress_children, &(&1.status == "merging_into_phase")),
      open_child_count: Enum.count(progress_children, &(&1.status not in @non_open_child_statuses))
    }
  end

  defp phase_child_package?(%WorkPackage{} = work_package) do
    work_package.kind == "phase_child" and filled_string?(work_package.parent_id)
  end

  defp filter_phase_work_packages(work_packages, filters) do
    Enum.filter(work_packages, &phase_work_package_matches_filters?(&1, filters))
  end

  defp phase_scope_filters(filters) do
    Enum.filter(filters, fn
      {:repo, repo} when is_binary(repo) -> true
      {:base_branch, base_branch} when is_binary(base_branch) -> true
      _filter -> false
    end)
  end

  @doc false
  @spec phase_work_package_matches_filters?(WorkPackage.t(), keyword()) :: boolean()
  def phase_work_package_matches_filters?(%WorkPackage{} = work_package, filters) do
    Enum.all?(filters, fn
      {:repo, repo} when is_binary(repo) -> repo_scope_match?(work_package.repo, repo)
      {:base_branch, base_branch} when is_binary(base_branch) -> work_package.base_branch == base_branch
      _filter -> true
    end)
  end

  defp require_work_request_scope(repo, %WorkRequest{} = work_request, %AccessGrant{} = grant) do
    with {:ok, filters} <- work_request_filters_for_grant(repo, grant) do
      if work_request_matches_filters?(work_request, filters) do
        :ok
      else
        {:error, :forbidden}
      end
    end
  end

  defp require_visible_work_request_scope(repo, %WorkRequest{} = work_request, %AccessGrant{} = grant) do
    case require_work_request_scope(repo, work_request, grant) do
      :ok -> :ok
      {:error, :forbidden} -> {:error, :not_found}
      error -> error
    end
  end

  defp work_request_matches_filters?(%WorkRequest{} = work_request, filters) do
    Enum.all?(filters, fn
      {:repo, repo} when is_binary(repo) -> repo_scope_match?(work_request.repo, repo)
      {:base_branch, base_branch} when is_binary(base_branch) -> work_request.base_branch == base_branch
      _filter -> true
    end)
  end

  defp explicit_phase_architect_grant?(%AccessGrant{grant_role: "architect", phase_id: phase_id}) when is_binary(phase_id) do
    String.trim(phase_id) != ""
  end

  defp explicit_phase_architect_grant?(%AccessGrant{}), do: false

  defp legacy_work_request_filters_for_grant(repo, %AccessGrant{
         grant_role: "architect",
         work_package_id: work_package_id,
         phase_id: nil
       })
       when is_binary(work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %WorkPackage{} = anchor} -> repo_base_filters(anchor.repo, anchor.base_branch)
      {:error, :not_found} -> {:error, :forbidden}
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_work_request_filters_for_grant(_repo, %AccessGrant{}), do: {:error, :forbidden}

  defp repo_base_filters(repo, base_branch) do
    with {:ok, repo} <- frozen_scope_value(repo),
         {:ok, base_branch} <- frozen_scope_value(base_branch) do
      {:ok, repo: repo, base_branch: base_branch}
    end
  end

  defp frozen_scope_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :forbidden}
      trimmed -> {:ok, trimmed}
    end
  end

  defp frozen_scope_value(_value), do: {:error, :forbidden}

  defp require_frozen_scope_match(%WorkPackage{} = anchor, %AccessGrant{} = grant) do
    if repo_scope_match?(grant.scope_repo, anchor.repo) and grant.scope_base_branch == anchor.base_branch do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp repo_scope_match?(expected_repo, actual_repo) when is_binary(expected_repo) and is_binary(actual_repo) do
    RepoIdentity.scope_match?(expected_repo, actual_repo,
      trusted_remotes: configured_trusted_repo_remotes(),
      local_path_remotes?: true
    )
  end

  defp repo_scope_match?(_expected_repo, _actual_repo), do: false

  defp cards_for_packages(repo, work_packages, repo_identity_catalog) do
    with {:ok, contexts} <- card_contexts_for_packages(repo, work_packages, repo_identity_catalog) do
      {:ok, Enum.map(contexts, & &1.card)}
    end
  end

  defp card_contexts_for_packages(repo, work_packages, repo_identity_catalog) do
    lineages_by_id = package_lineages(repo, work_packages)

    work_packages
    |> Enum.map(&card_context(repo, &1, Map.get(lineages_by_id, &1.id, empty_lineage(&1.id)), repo_identity_catalog))
    |> collect_or_error()
  end

  defp active_blocking_edges_from_card_contexts(_repo, []), do: {:ok, []}

  defp active_blocking_edges_from_card_contexts(repo, contexts) do
    work_package_ids = Enum.map(contexts, & &1.work_package.id)

    with {:ok, planned_slices_by_work_package_id} <- linked_planned_slices_by_work_package_id(repo, work_package_ids) do
      edges =
        contexts
        |> Enum.flat_map(fn %{work_package: work_package, blockers: blockers} ->
          linked_planned_slice = Map.get(planned_slices_by_work_package_id, work_package.id)

          blockers
          |> Enum.filter(& &1.active)
          |> Enum.map(&active_blocking_edge(&1, work_package, linked_planned_slice))
        end)
        |> sort_active_blocking_edges()

      {:ok, edges}
    end
  end

  defp linked_planned_slices_by_work_package_id(_repo, []), do: {:ok, %{}}

  defp linked_planned_slices_by_work_package_id(repo, work_package_ids) do
    planned_slices =
      repo.all(
        from(planned_slice in PlannedSlice,
          where: planned_slice.work_package_id in ^work_package_ids,
          order_by: [asc: planned_slice.work_package_id, asc: planned_slice.sequence, asc: planned_slice.id]
        )
      )

    planned_slices_by_work_package_id =
      planned_slices
      |> Enum.group_by(& &1.work_package_id)
      |> Map.new(fn
        {work_package_id, [planned_slice]} ->
          {work_package_id, planned_slice}

        {work_package_id, _duplicates} ->
          {work_package_id, nil}
      end)

    {:ok, planned_slices_by_work_package_id}
  end

  defp active_blocking_edge(blocker, %WorkPackage{} = work_package, %PlannedSlice{} = planned_slice) do
    fallback_from = %{kind: "slice", id: planned_slice.id}
    from = blocker.blocked_by || fallback_from
    to = blocker.blocked_item || %{kind: "work_package", id: work_package.id}

    blocker
    |> build_active_blocking_edge(work_package, from, to)
    |> Map.put(:work_request_id, planned_slice.work_request_id)
    |> Map.put(:planned_slice_id, planned_slice.id)
  end

  defp active_blocking_edge(blocker, %WorkPackage{} = work_package, _linked_planned_slice) do
    from = blocker.blocked_by || %{kind: "work_package", id: work_package.id}
    to = blocker.blocked_item || %{kind: "work_package", id: work_package.id}

    build_active_blocking_edge(blocker, work_package, from, to)
  end

  defp build_active_blocking_edge(blocker, %WorkPackage{} = work_package, from, to) do
    %{
      id: active_blocking_edge_id(blocker.id, from, to),
      blocker_id: blocker.id,
      from: from,
      to: to,
      summary: blocker.summary,
      body: blocker.body,
      updated_at: blocker.updated_at,
      work_package_id: work_package.id
    }
  end

  defp active_blocking_edge_id(blocker_id, from, to) do
    material = [blocker_id, from.kind, from.id, to.kind, to.id]

    "active_blocking_edge_" <> Base.url_encode64(:crypto.hash(:sha256, Enum.join(material, ":")), padding: false)
  end

  defp sort_active_blocking_edges(edges) do
    Enum.sort_by(edges, fn edge ->
      from = Map.fetch!(edge, :from)
      to = Map.fetch!(edge, :to)

      {
        edge.updated_at || "",
        edge.id || "",
        from.kind || "",
        from.id || "",
        to.kind || "",
        to.id || ""
      }
    end)
  end

  defp work_request_cards(repo, work_requests, opts) do
    with {:ok, summaries} <- work_request_card_summaries(repo, work_requests, opts) do
      repo_identity_catalog = repo_identity_catalog_from_opts(opts, Enum.map(work_requests, & &1.repo))
      {:ok, Enum.map(work_requests, &work_request_card(&1, summaries, repo_identity_catalog))}
    end
  end

  defp visible_work_request_cards(cards) do
    Enum.reject(cards, &(not is_nil(&1.archived_at)))
  end

  defp ordered_work_requests(work_requests) do
    Enum.sort_by(work_requests, fn %WorkRequest{} = work_request ->
      {sortable_timestamp(work_request.inserted_at), work_request.id || ""}
    end)
  end

  @doc false
  @spec ordered_sequence_records([struct()]) :: [struct()]
  def ordered_sequence_records(records) do
    Enum.sort_by(records, fn record ->
      {Map.get(record, :sequence) || 0, Map.get(record, :id) || ""}
    end)
  end

  defp sortable_timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp sortable_timestamp(_timestamp), do: ""

  defp planning_state(repo, work_package_id) do
    case PlanningRepository.get_state(repo, work_package_id) do
      {:ok, %State{} = state} ->
        {:ok, state}

      {:error, :not_found} ->
        with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
          {:ok, %State{work_package: work_package}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp repo_identity_repo_values(repo) do
    Enum.flat_map([WorkPackage, WorkRequest, SoloSession], &repo_values(repo, &1))
  end

  defp repo_values(repo, schema) do
    repo.all(
      from(record in schema,
        where: not is_nil(record.repo) and record.repo != "",
        distinct: true,
        select: record.repo
      )
    )
  end

  defp work_request_detail_repo_identity_catalog_for_grant(repo, %AccessGrant{} = grant, fallback_repo_values) do
    with {:ok, filters} <- work_request_filters_for_grant(repo, grant),
         {:ok, work_requests} <- WorkRequestRepository.list(repo, Map.new(filters)) do
      {:ok, build_repo_identity_catalog(Enum.map(work_requests, & &1.repo) ++ fallback_repo_values)}
    end
  end

  defp repo_identity_catalog_from_repo(repo, opts, repo_values) do
    case Keyword.fetch(opts, :repo_identity_catalog) do
      {:ok, repo_identity_catalog} ->
        {:ok, repo_identity_catalog}

      :error ->
        {:ok, build_repo_identity_catalog(repo_identity_repo_values(repo) ++ repo_values)}
    end
  end

  @doc false
  @spec repo_identity_catalog_from_opts(keyword(), [String.t() | nil]) :: map()
  def repo_identity_catalog_from_opts(opts, repo_values) do
    Keyword.get_lazy(opts, :repo_identity_catalog, fn -> build_repo_identity_catalog(repo_values) end)
  end

  defp build_repo_identity_catalog(repo_values) do
    build_repo_identity_catalog(repo_values, configured_trusted_repo_remotes())
  end

  defp build_repo_identity_catalog(repo_values, trusted_remotes, opts \\ []) when is_list(trusted_remotes) do
    repo_identity_opts =
      opts
      |> Keyword.put(:trusted_remotes, Enum.uniq(trusted_remotes))

    RepoIdentity.catalog(repo_values, repo_identity_opts)
  end

  defp configured_trusted_repo_remotes do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
  end

  defp local_operator_trusted_repo_remotes do
    (configured_trusted_repo_remotes() ++ local_operator_origin_remotes())
    |> Enum.uniq()
  end

  defp local_operator_origin_remotes do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_root)
    |> RepoIdentity.local_git_origin_remote()
    |> List.wrap()
  end

  defp safe_read(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)

    if message |> String.downcase() |> busy_message?() do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end

  defp busy_message?(message) do
    String.contains?(message, "busy") or String.contains?(message, "locked")
  end

  defp group_cards(cards) do
    by_status = Enum.group_by(cards, & &1.status)
    statuses = Enum.uniq(WorkPackage.statuses() ++ Map.keys(by_status))

    Map.new(statuses, fn status ->
      {status, Map.get(by_status, status, [])}
    end)
  end

  defp group_statuses(groups) when is_map(groups), do: Enum.uniq(WorkPackage.statuses() ++ Map.keys(groups))

  defp summary(%State{} = state, grants, agent_runs, blockers, guidance_requests, comment_context) do
    runtime = runtime_summary(agent_runs)
    comment_counts = CommentProjection.counts_for(comment_context, "work_package", state.work_package.id)

    %{
      artifact_count: length(state.artifacts),
      finding_count: length(state.findings),
      progress_event_count: length(state.progress_events),
      comment_count: comment_counts.comment_count,
      open_comment_count: comment_counts.open_comment_count,
      active_blocker_count: Enum.count(blockers, & &1.active),
      guidance_request_count: length(guidance_requests),
      grant_count: length(grants),
      active_grant_count: Enum.count(grants, &active_grant?/1),
      agent_run_count: length(agent_runs),
      active_agent_run_count: Enum.count(agent_runs, &(&1.status in AgentRun.active_statuses())),
      queued_agent_run_count: runtime.queued_count,
      stopped_agent_run_count: runtime.stopped_count,
      failed_agent_run_count: runtime.failed_count,
      stale_agent_run_count: runtime.stale_count,
      runtime: runtime,
      latest_progress_at: latest_progress_at(state.progress_events),
      plan: plan_summary(state.plan_nodes)
    }
  end

  defp work_request_card_summaries(_repo, [], _opts), do: {:ok, %{}}

  defp work_request_card_summaries(repo, work_requests, opts) do
    work_request_ids = Enum.map(work_requests, & &1.id)

    with {:ok, question_context} <- work_request_question_context(repo, work_request_ids),
         {:ok, decision_counts} <- work_request_decision_counts(repo, work_request_ids),
         {:ok, planned_slices} <- work_request_planned_slices(repo, work_request_ids),
         {:ok, comment_context} <- work_request_card_comment_context(repo, work_requests, planned_slices),
         {:ok, work_package_contexts} <- work_request_card_work_package_contexts(repo, planned_slices, opts) do
      question_counts = question_context.counts
      planned_slices_by_request = Enum.group_by(planned_slices, & &1.work_request_id)

      with {:ok, delivery_boards} <-
             work_request_card_delivery_boards(repo, work_requests, planned_slices_by_request, work_package_contexts) do
        delivery_state_opts = work_request_delivery_state_opts(opts)

        work_request_card_summaries(
          work_requests,
          question_counts,
          question_context.states,
          decision_counts,
          planned_slices_by_request,
          comment_context,
          work_package_contexts,
          %{boards: delivery_boards, state_opts: delivery_state_opts}
        )
      end
    end
  end

  defp work_request_card_summaries(
         work_requests,
         question_counts,
         question_states,
         decision_counts,
         planned_slices_by_request,
         comment_context,
         work_package_contexts,
         delivery_context
       ) do
    delivery_boards = Map.fetch!(delivery_context, :boards)
    delivery_state_opts = Map.fetch!(delivery_context, :state_opts)

    visible_planned_slices_by_request =
      visible_planned_slices_by_request(work_requests, planned_slices_by_request, delivery_boards)

    planned_slice_counts =
      visible_planned_slices_by_request
      |> Map.values()
      |> Enum.flat_map(& &1)
      |> Enum.map(&{&1.work_request_id, &1.status})
      |> status_counts()

    summaries =
      Map.new(work_requests, fn %WorkRequest{} = work_request ->
        planned_slices = Map.get(visible_planned_slices_by_request, work_request.id, [])
        all_planned_slices = Map.get(planned_slices_by_request, work_request.id, [])
        comment_counts = CommentProjection.work_request_counts(comment_context, work_request, all_planned_slices)
        open_question_count = status_count(question_counts, work_request.id, "open")

        question_state =
          Map.get(question_states, work_request.id, %{
            open_count: open_question_count,
            latest_gate_at: nil
          })

        completion_state =
          work_request
          |> WorkRequestCompletion.visible_state(
            question_state,
            planned_slices,
            work_package_contexts,
            completion_deliveries_by_slice_id(Map.get(delivery_boards, work_request.id))
          )

        operational_state =
          work_request_operational_state(
            work_request,
            planned_slices,
            work_package_contexts,
            completion_state,
            Map.get(delivery_boards, work_request.id),
            delivery_state_opts
          )

        {work_request.id,
         %{
           open_question_count: open_question_count,
           answered_question_count: status_count(question_counts, work_request.id, "answered"),
           closed_question_count: status_count(question_counts, work_request.id, "closed"),
           decision_count: Map.get(decision_counts, work_request.id, 0),
           comment_count: comment_counts.comment_count,
           open_comment_count: comment_counts.open_comment_count,
           planned_slice_count: status_count(planned_slice_counts, work_request.id, "planned"),
           approved_slice_count: status_count(planned_slice_counts, work_request.id, "approved"),
           dispatched_slice_count: status_count(planned_slice_counts, work_request.id, "dispatched"),
           skipped_slice_count: status_count(planned_slice_counts, work_request.id, "skipped"),
           completed_at: timestamp(completion_state.completed_at),
           completion_source: work_request.completion_source,
           archived_at: timestamp(completion_state.archived_at),
           operational_state: operational_state
         }}
      end)

    {:ok, summaries}
  end

  defp work_request_card_delivery_boards(repo, work_requests, planned_slices_by_request, work_package_contexts) do
    DeliveryBoard.project_many(
      repo,
      work_requests,
      planned_slices_by_request,
      delivery_board_card_opts(work_package_contexts)
    )
  end

  defp delivery_board_card_opts(work_package_contexts) do
    [
      slice_projection: :operational_state,
      visible_work_package_ids: Map.keys(work_package_contexts),
      work_package_contexts: work_package_contexts
    ]
  end

  defp work_request_delivery_state_opts(opts) do
    case Keyword.get(opts, :grant) do
      %AccessGrant{} -> [include_package_fields?: false]
      _other -> []
    end
  end

  defp work_request_card_work_package_contexts(repo, planned_slices, opts) do
    case Keyword.get(opts, :grant) do
      %AccessGrant{} = grant -> planned_slice_work_package_contexts_for_grant(repo, planned_slices, grant)
      _grant -> planned_slice_work_package_contexts(repo, planned_slices)
    end
  end

  defp work_request_card_comment_context(repo, work_requests, planned_slices) do
    targets =
      Enum.map(work_requests, &{"work_request", &1.id}) ++
        Enum.map(planned_slices, &{"planned_slice", &1.id})

    comment_count_context(repo, targets)
  end

  defp work_request_comment_context(repo, %WorkRequest{} = work_request, planned_slices) do
    comment_context(repo, [{"work_request", work_request.id} | Enum.map(planned_slices, &{"planned_slice", &1.id})])
  end

  @doc false
  @spec comment_count_context(repo(), [{String.t(), String.t()}]) :: {:ok, map()} | {:error, dashboard_error()}
  def comment_count_context(repo, targets) do
    with {:ok, counts} <- CommentRepository.counts_for_targets(repo, targets) do
      {:ok, %{comments: %{}, counts: counts}}
    end
  end

  @doc false
  @spec comment_context(repo(), [{String.t(), String.t()}]) :: {:ok, map()} | {:error, dashboard_error()}
  def comment_context(repo, targets) do
    with {:ok, comments} <- CommentRepository.list_for_targets(repo, targets),
         {:ok, counts} <- CommentRepository.counts_for_targets(repo, targets) do
      {:ok, %{comments: comments, counts: counts}}
    end
  end

  defp visible_planned_slices_by_request(work_requests, planned_slices_by_request, delivery_boards) do
    Map.new(work_requests, fn %WorkRequest{} = work_request ->
      planned_slices = Map.get(planned_slices_by_request, work_request.id, [])
      delivery_board = Map.get(delivery_boards, work_request.id)

      {work_request.id, visible_planned_slices(planned_slices, delivery_board)}
    end)
  end

  @doc false
  @spec visible_planned_slices([PlannedSlice.t()], map() | nil) :: [PlannedSlice.t()]
  def visible_planned_slices(planned_slices, nil), do: planned_slices

  def visible_planned_slices(planned_slices, delivery_board) do
    visible_by_id = DeliverySliceProjection.slices_by_id(delivery_board)

    Enum.filter(planned_slices, &Map.has_key?(visible_by_id, &1.id))
  end

  defp completion_deliveries_by_slice_id(delivery_board) do
    delivery_board
    |> DeliverySliceProjection.slices_by_id()
    |> Enum.flat_map(fn {slice_id, delivery_slice} ->
      case completion_delivery_outcome(delivery_slice) do
        outcome when is_binary(outcome) and outcome != "" -> [{slice_id, %{outcome: outcome}}]
        _outcome -> []
      end
    end)
    |> Map.new()
  end

  defp completion_delivery_outcome(%{} = delivery_slice) do
    map_value(delivery_slice, "delivery_outcome") ||
      case map_value(delivery_slice, "delivery") do
        %{} = delivery -> map_value(delivery, "outcome")
        _delivery -> nil
      end
  end

  defp completion_delivery_outcome(_delivery_slice), do: nil

  defp work_request_question_context(repo, work_request_ids) do
    rows =
      chunked_work_request_rows(work_request_ids, fn chunk ->
        from(question in ClarificationQuestion,
          where: question.work_request_id in ^chunk,
          select: {question.work_request_id, question.status, question.updated_at}
        )
        |> repo.all()
      end)

    counts =
      rows
      |> Enum.map(fn {work_request_id, status, _updated_at} -> {work_request_id, status} end)
      |> status_counts()

    states =
      rows
      |> Enum.group_by(fn {work_request_id, _status, _updated_at} -> work_request_id end)
      |> Map.new(fn {work_request_id, questions} ->
        {work_request_id,
         %{
           open_count: Enum.count(questions, fn {_work_request_id, status, _updated_at} -> status == "open" end),
           latest_gate_at: latest_datetime(Enum.map(questions, fn {_work_request_id, _status, updated_at} -> updated_at end))
         }}
      end)

    {:ok, %{counts: counts, states: states}}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp work_request_decision_counts(repo, work_request_ids) do
    rows =
      chunked_work_request_rows(work_request_ids, fn chunk ->
        from(decision in DecisionLogEntry,
          where: decision.work_request_id in ^chunk,
          select: decision.work_request_id
        )
        |> repo.all()
      end)

    {:ok, Enum.frequencies(rows)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp work_request_planned_slices(repo, work_request_ids) do
    rows =
      chunked_work_request_rows(work_request_ids, fn chunk ->
        from(planned_slice in PlannedSlice,
          where: planned_slice.work_request_id in ^chunk,
          order_by: [asc: planned_slice.work_request_id, asc: planned_slice.sequence, asc: planned_slice.inserted_at]
        )
        |> repo.all()
      end)

    {:ok, rows}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp chunked_work_request_rows(work_request_ids, fetch_chunk) do
    work_request_ids
    |> Enum.chunk_every(@work_request_count_chunk_size)
    |> Enum.flat_map(fetch_chunk)
  end

  defp status_counts(rows) do
    Enum.reduce(rows, %{}, fn {work_request_id, status}, counts ->
      Map.update(counts, work_request_id, %{status => 1}, &Map.update(&1, status, 1, fn count -> count + 1 end))
    end)
  end

  defp status_count(counts, work_request_id, status) do
    counts
    |> Map.get(work_request_id, %{})
    |> Map.get(status, 0)
  end

  defp work_request_card(%WorkRequest{} = work_request, summaries, repo_identity_catalog) do
    Map.merge(Map.fetch!(summaries, work_request.id), %{
      id: work_request.id,
      title: redacted_text(work_request.title),
      repo: work_request.repo,
      base_branch: work_request.base_branch,
      work_type: work_request.work_type,
      desired_dispatch_shape: work_request.desired_dispatch_shape,
      creator: work_request_creator(work_request),
      status: work_request.status,
      inserted_at: timestamp(work_request.inserted_at),
      updated_at: timestamp(work_request.updated_at)
    })
    |> put_repo_identity_fields(repo_identity_catalog, work_request.repo)
  end

  defp solo_session_cards(repo, sessions, repo_identity_catalog) do
    session_ids = Enum.map(sessions, & &1.id)

    with {:ok, entry_counts} <- solo_session_entry_counts(repo, session_ids),
         {:ok, latest_entries} <- latest_solo_session_entries(repo, session_ids),
         {:ok, active_blocker_counts} <- solo_session_active_blocker_counts(repo, session_ids) do
      cards =
        Enum.map(sessions, fn %SoloSession{} = session ->
          solo_session_card(
            session,
            Map.get(entry_counts, session.id, []),
            Map.get(latest_entries, session.id),
            Map.get(active_blocker_counts, session.id, 0),
            repo_identity_catalog
          )
        end)

      {:ok, cards}
    end
  end

  defp solo_session_entry_counts(_repo, []), do: {:ok, %{}}

  defp solo_session_entry_counts(repo, session_ids) do
    rows =
      session_ids
      |> Enum.chunk_every(@solo_session_query_chunk_size)
      |> Enum.flat_map(fn chunk ->
        repo.all(
          from(entry in SoloSessionEntry,
            where: entry.solo_session_id in ^chunk,
            group_by: [entry.solo_session_id, entry.entry_kind],
            select: {entry.solo_session_id, entry.entry_kind, count(entry.id)}
          )
        )
      end)

    counts =
      Enum.reduce(rows, %{}, fn {session_id, kind, count}, acc ->
        entry_count = %{kind: kind || "unknown", label: status_label(kind || "unknown"), count: count}
        Map.update(acc, session_id, [entry_count], &[entry_count | &1])
      end)
      |> Map.new(fn {session_id, counts} ->
        {session_id, Enum.sort_by(counts, & &1.kind)}
      end)

    {:ok, counts}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp solo_session_active_blocker_counts(_repo, []), do: {:ok, %{}}

  defp solo_session_active_blocker_counts(repo, session_ids) do
    entries =
      session_ids
      |> Enum.chunk_every(@solo_session_query_chunk_size)
      |> Enum.flat_map(fn chunk ->
        repo.all(
          from(entry in SoloSessionEntry,
            where: entry.solo_session_id in ^chunk,
            where: entry.entry_kind == "blocker",
            order_by: [asc: entry.solo_session_id, asc: entry.sequence, asc: entry.id],
            select: %{
              solo_session_id: entry.solo_session_id,
              id: entry.id,
              entry_kind: entry.entry_kind,
              sequence: entry.sequence,
              status: entry.status,
              payload: entry.payload
            }
          )
        )
      end)

    counts =
      entries
      |> Enum.group_by(& &1.solo_session_id)
      |> Map.new(fn {session_id, session_entries} ->
        {session_id, SoloSessionNormalization.active_blocker_count(session_entries)}
      end)

    {:ok, counts}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp latest_solo_session_entries(_repo, []), do: {:ok, %{}}

  defp latest_solo_session_entries(repo, session_ids) do
    entries =
      session_ids
      |> Enum.chunk_every(@solo_session_query_chunk_size)
      |> Enum.flat_map(fn chunk -> repo.all(latest_solo_session_entries_query(chunk)) end)

    {:ok, Map.new(entries, &{&1.solo_session_id, solo_session_entry(&1)})}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp latest_solo_session_entries_query(session_ids) do
    from(entry in SoloSessionEntry,
      where: entry.solo_session_id in ^session_ids,
      where:
        entry.sequence ==
          fragment(
            """
            SELECT MAX(latest.sequence)
            FROM sympp_solo_session_entries AS latest
            WHERE latest.solo_session_id = ?
            """,
            entry.solo_session_id
          ),
      order_by: [asc: entry.solo_session_id, desc: entry.created_at, desc: entry.id],
      select: %{
        solo_session_id: entry.solo_session_id,
        entry_kind: entry.entry_kind,
        status: entry.status,
        title: entry.title,
        body: entry.body,
        payload: entry.payload,
        created_at: entry.created_at
      }
    )
  end

  defp solo_session_card(%SoloSession{} = session, entry_counts, latest_entry, active_blocker_count, repo_identity_catalog) do
    %{
      id: session.id,
      title: solo_session_title(session),
      repo: session.repo,
      base_branch: session.base_branch,
      caller_id: redacted_text(session.caller_id),
      status: session.status,
      last_activity_at: timestamp(session.last_activity_at),
      inserted_at: timestamp(session.inserted_at),
      updated_at: timestamp(session.updated_at),
      active_blocker_count: active_blocker_count,
      entry_counts: entry_counts,
      latest_entry: latest_entry
    }
    |> put_repo_identity_fields(repo_identity_catalog, session.repo)
  end

  defp solo_session_payload(%SoloSession{} = session, repo_identity_catalog) do
    %{
      id: session.id,
      title: solo_session_title(session),
      repo: session.repo,
      base_branch: session.base_branch,
      workspace_path: redacted_text(session.workspace_path),
      caller_id: redacted_text(session.caller_id),
      status: session.status,
      last_activity_at: timestamp(session.last_activity_at),
      archived_at: timestamp(session.archived_at),
      inserted_at: timestamp(session.inserted_at),
      updated_at: timestamp(session.updated_at)
    }
    |> put_repo_identity_fields(repo_identity_catalog, session.repo)
  end

  defp solo_session_title(%SoloSession{title: title, id: id}) do
    title
    |> redacted_text()
    |> present_text()
    |> Kernel.||(id)
  end

  defp solo_session_entry(entry) when is_map(entry) do
    %{
      kind: Map.get(entry, :entry_kind),
      kind_label: status_label(Map.get(entry, :entry_kind)),
      status: Map.get(entry, :status),
      title: entry |> Map.get(:title) |> redacted_text() |> snippet(@solo_session_snippet_limit),
      body: entry |> Map.get(:body) |> redacted_text() |> snippet(@solo_session_snippet_limit),
      payload: entry |> Map.get(:payload) |> redacted_payload(),
      created_at: entry |> Map.get(:created_at) |> timestamp()
    }
  end

  defp solo_session_detail_entry(%SoloSessionEntry{} = entry) do
    %{
      id: entry.id,
      sequence: entry.sequence,
      kind: entry.entry_kind,
      kind_label: status_label(entry.entry_kind),
      status: entry.status,
      status_label: status_label(entry.status),
      title: entry.title |> redacted_text() |> present_text(),
      body: entry.body |> redacted_text() |> present_text(),
      payload: redacted_payload(entry.payload),
      created_at: timestamp(entry.created_at),
      updated_at: timestamp(entry.updated_at)
    }
  end

  defp redacted_payload(payload) when is_map(payload), do: Redactor.redact_output(payload)
  defp redacted_payload(_payload), do: %{}

  defp present_text(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp present_text(_value), do: nil

  defp snippet(nil, _limit), do: nil

  defp snippet(value, limit) when is_binary(value) do
    value =
      value
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      value == "" -> nil
      String.length(value) <= limit -> value
      true -> String.slice(value, 0, max(limit - 3, 0)) <> "..."
    end
  end

  defp status_label(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp status_label(status), do: to_string(status)

  defp human_guidance_request_cards(repo, opts) do
    rows =
      repo.all(
        from(guidance_request in GuidanceRequest,
          join: work_package in WorkPackage,
          on: work_package.id == guidance_request.work_package_id,
          where: guidance_request.status == "human_info_needed",
          order_by: [asc: guidance_request.inserted_at, asc: guidance_request.id],
          select: {guidance_request, work_package}
        )
      )

    with {:ok, repo_identity_catalog} <-
           repo_identity_catalog_from_repo(repo, opts, Enum.map(rows, fn {_guidance_request, work_package} -> work_package.repo end)) do
      {:ok,
       Enum.map(rows, fn {guidance_request, work_package} ->
         guidance_request_card(guidance_request, work_package, repo_identity_catalog)
       end)}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp guidance_request_card(%GuidanceRequest{} = guidance_request, %WorkPackage{} = work_package, repo_identity_catalog) do
    guidance_request(guidance_request)
    |> Map.merge(%{
      work_package_title: redacted_text(work_package.title),
      package_kind: work_package.kind,
      repo: work_package.repo,
      base_branch: work_package.base_branch,
      phase_id: work_package.phase_id
    })
    |> put_repo_identity_fields(repo_identity_catalog, work_package.repo)
  end

  defp work_request_payload(%WorkRequest{} = work_request, repo_identity_catalog) do
    %{
      id: work_request.id,
      title: redacted_text(work_request.title),
      repo: work_request.repo,
      base_branch: work_request.base_branch,
      work_type: work_request.work_type,
      human_description: redacted_text(work_request.human_description),
      constraints: redacted_json(work_request.constraints || %{}),
      desired_dispatch_shape: work_request.desired_dispatch_shape,
      creator: work_request_creator(work_request),
      status: work_request.status,
      inserted_at: timestamp(work_request.inserted_at),
      updated_at: timestamp(work_request.updated_at)
    }
    |> put_repo_identity_fields(repo_identity_catalog, work_request.repo)
  end

  defp work_request_creator(%WorkRequest{} = work_request) do
    %{
      kind: work_request.creator_kind,
      name: redacted_text(work_request.creator_name),
      via: work_request.created_via
    }
  end

  @doc false
  @spec work_request_payload(
          WorkRequest.t(),
          [ClarificationQuestion.t()],
          [PlannedSlice.t()],
          map(),
          map(),
          map(),
          keyword()
        ) :: map()
  def work_request_payload(
        %WorkRequest{} = work_request,
        questions,
        planned_slices,
        work_package_contexts,
        repo_identity_catalog,
        comment_context,
        opts
      ) do
    question_state = %{
      open_count: Enum.count(questions, &(&1.status == "open")),
      latest_gate_at: latest_datetime(Enum.map(questions, & &1.updated_at))
    }

    completion_state =
      work_request
      |> WorkRequestCompletion.visible_state(
        question_state,
        planned_slices,
        work_package_contexts,
        completion_deliveries_by_slice_id(Keyword.get(opts, :delivery_board))
      )

    work_request
    |> work_request_payload(repo_identity_catalog)
    |> Map.put(:completed_at, timestamp(completion_state.completed_at))
    |> Map.put(:completion_source, work_request.completion_source)
    |> Map.put(:archived_at, timestamp(completion_state.archived_at))
    |> Map.put(:archive_reason, work_request.archive_reason)
    |> Map.put(
      :operational_state,
      work_request_operational_state(
        work_request,
        planned_slices,
        work_package_contexts,
        completion_state,
        Keyword.get(opts, :delivery_board),
        Keyword.get(opts, :delivery_state_opts, [])
      )
    )
    |> CommentProjection.put_counts(
      CommentProjection.work_request_counts(
        comment_context,
        work_request,
        Keyword.get(opts, :comment_planned_slices, planned_slices)
      )
    )
  end

  defp work_request_operational_state(
         %WorkRequest{} = work_request,
         planned_slices,
         work_package_contexts,
         completion_state,
         delivery_board,
         delivery_state_opts
       ) do
    slice_states =
      planned_slice_operational_states(planned_slices, work_package_contexts, delivery_board, delivery_state_opts)

    attention_items = aggregate_operational_attention(slice_states)
    promoted_state = primary_work_request_slice_state(slice_states)

    cond do
      completion_state.archived_at ->
        completed_work_request_operational_state(work_request, attention_items)

      operator_completed_work_request?(work_request, completion_state) ->
        completed_work_request_operational_state(work_request, attention_items)

      delivery_truth_operational_state?(promoted_state) ->
        promoted_work_request_operational_state(work_request, promoted_state, planned_slices, attention_items)
        |> DeliverySliceProjection.redact_reasons(delivery_state_opts)

      completion_state.completed? ->
        completed_work_request_operational_state(work_request, attention_items)

      work_request.status in @delivery_promotion_blocking_work_request_statuses ->
        base_work_request_operational_state(work_request.status, attention_items)

      promoted_state ->
        promoted_work_request_operational_state(work_request, promoted_state, planned_slices, attention_items)

      true ->
        base_work_request_operational_state(work_request.status, attention_items)
    end
  end

  defp operator_completed_work_request?(%WorkRequest{completion_source: "operator"}, %{completed?: true}), do: true
  defp operator_completed_work_request?(%WorkRequest{}, _completion_state), do: false

  defp completed_work_request_operational_state(%WorkRequest{completion_source: "operator"} = work_request, attention_items) do
    operational_state(
      "completed",
      "Completed",
      "success",
      "WorkRequest was manually marked completed by the local operator.",
      work_request.status,
      attention_items
    )
  end

  defp completed_work_request_operational_state(%WorkRequest{} = work_request, attention_items) do
    operational_state(
      "completed",
      "Completed",
      "success",
      "All WorkRequest questions, slices, linked packages, blockers, and active runtimes are terminal.",
      work_request.status,
      attention_items
    )
  end

  defp base_work_request_operational_state("human_info_needed" = status, attention_items) do
    operational_state(
      "human_info_needed",
      "Human Info Needed",
      "warning",
      "WorkRequest is waiting for a human answer before architecture can proceed.",
      status,
      attention_items
    )
  end

  defp base_work_request_operational_state("ready_for_clarification" = status, attention_items) do
    operational_state("clarifying", "Clarifying", "warning", "WorkRequest is still in clarification.", status, attention_items)
  end

  defp base_work_request_operational_state("clarifying" = status, attention_items) do
    operational_state("clarifying", "Clarifying", "warning", "WorkRequest is still in clarification.", status, attention_items)
  end

  defp base_work_request_operational_state("draft" = status, attention_items) do
    operational_state("not_started", "Not Started", "neutral", "WorkRequest is still a draft.", status, attention_items)
  end

  defp base_work_request_operational_state("ready_for_slicing" = status, attention_items) do
    operational_state(
      "ready_for_slicing",
      "Ready For Slicing",
      "neutral",
      "WorkRequest is ready for an architect to author planned slices.",
      status,
      attention_items
    )
  end

  defp base_work_request_operational_state("sliced" = status, attention_items) do
    operational_state("sliced", "Sliced", "neutral", "WorkRequest has been marked sliced.", status, attention_items)
  end

  defp base_work_request_operational_state(status, attention_items) do
    key = status || "unknown"
    operational_state(key, status_label(key), "neutral", "Raw WorkRequest lifecycle status is #{key}.", status, attention_items)
  end

  defp planned_slice_operational_states(planned_slices, work_package_contexts, delivery_board, delivery_state_opts) do
    delivery_slices_by_id = DeliverySliceProjection.slices_by_id(delivery_board)

    Enum.map(planned_slices, fn %PlannedSlice{} = planned_slice ->
      planned_slice_operational_state(
        planned_slice,
        Map.get(work_package_contexts, planned_slice.work_package_id),
        Map.get(delivery_slices_by_id, planned_slice.id),
        delivery_state_opts
      )
    end)
  end

  defp primary_work_request_slice_state([]), do: nil

  defp primary_work_request_slice_state(slice_states) do
    Enum.find_value(@work_request_slice_state_priority, fn key ->
      Enum.find(slice_states, &(Map.get(&1, :key) == key))
    end)
  end

  defp delivery_truth_operational_state?(%{key: "needs_closeout"}), do: true
  defp delivery_truth_operational_state?(%{delivery_outcome: outcome}) when is_binary(outcome), do: true
  defp delivery_truth_operational_state?(_state), do: false

  defp promoted_work_request_operational_state(%WorkRequest{} = work_request, promoted_state, planned_slices, attention_items) do
    promoted_state
    |> operational_activity_fields()
    |> Map.merge(
      operational_state(
        promoted_state.key,
        promoted_state.label,
        promoted_state.tone,
        "Most actionable planned-slice or linked-package state is #{promoted_state.label} across #{length(planned_slices)} slice(s).",
        work_request.status,
        attention_items
      )
    )
  end

  defp aggregate_operational_attention(operational_states) do
    operational_states
    |> Enum.flat_map(&Map.get(&1, :attention_items, []))
    |> Enum.uniq_by(&Map.get(&1, :key))
  end

  defp guidance_request(%GuidanceRequest{} = guidance_request) do
    %{
      id: guidance_request.id,
      work_package_id: guidance_request.work_package_id,
      summary: redacted_text(guidance_request.summary),
      question: redacted_text(guidance_request.question),
      context: redacted_text(guidance_request.context),
      status: guidance_request.status,
      requested_by: redacted_text(guidance_request.requested_by),
      answer: redacted_text(guidance_request.answer),
      answered_by: redacted_text(guidance_request.answered_by),
      answered_at: timestamp(guidance_request.answered_at),
      human_info_reason: redacted_text(guidance_request.human_info_reason),
      recommended_language: redacted_text(guidance_request.recommended_language),
      decision_prompt: redacted_json(guidance_request.decision_prompt),
      blocker_id: guidance_request.blocker_id,
      inserted_at: timestamp(guidance_request.inserted_at),
      updated_at: timestamp(guidance_request.updated_at)
    }
  end

  @doc false
  @spec clarification_question(ClarificationQuestion.t()) :: map()
  def clarification_question(%ClarificationQuestion{} = question) do
    %{
      id: question.id,
      work_request_id: question.work_request_id,
      sequence: question.sequence,
      category: redacted_text(question.category),
      question: redacted_text(question.question),
      why_needed: redacted_text(question.why_needed),
      decision_prompt: redacted_json(question.decision_prompt),
      status: question.status,
      asked_by_agent_run_id: question.asked_by_agent_run_id,
      answer: redacted_text(question.answer),
      answered_by: redacted_text(question.answered_by),
      answered_at: timestamp(question.answered_at),
      inserted_at: timestamp(question.inserted_at),
      updated_at: timestamp(question.updated_at)
    }
  end

  @doc false
  @spec decision_log_entry(DecisionLogEntry.t()) :: map()
  def decision_log_entry(%DecisionLogEntry{} = decision) do
    %{
      id: decision.id,
      work_request_id: decision.work_request_id,
      sequence: decision.sequence,
      source_type: decision.source_type,
      source_id: redacted_text(decision.source_id),
      decision: redacted_text(decision.decision),
      rationale: redacted_text(decision.rationale),
      scope_impact: redacted_text(decision.scope_impact),
      created_by: redacted_text(decision.created_by),
      created_at: timestamp(decision.created_at),
      inserted_at: timestamp(decision.inserted_at),
      updated_at: timestamp(decision.updated_at)
    }
  end

  @doc false
  @spec planned_slice_payloads([PlannedSlice.t()], map(), boolean(), map(), keyword()) :: [map()]
  def planned_slice_payloads(planned_slices, work_package_contexts, include_dispatch_linkage?, comment_context, opts) do
    delivery_slices_by_id = opts |> Keyword.get(:delivery_board) |> DeliverySliceProjection.slices_by_id()

    Enum.map(planned_slices, fn slice ->
      planned_slice(slice, work_package_contexts,
        include_dispatch_linkage?: include_dispatch_linkage?,
        comment_context: comment_context,
        delivery_slice: Map.get(delivery_slices_by_id, slice.id)
      )
    end)
  end

  defp planned_slice(%PlannedSlice{} = planned_slice, work_package_statuses, opts) do
    %{
      id: planned_slice.id,
      work_request_id: planned_slice.work_request_id,
      sequence: planned_slice.sequence,
      title: redacted_text(planned_slice.title),
      goal: redacted_text(planned_slice.goal),
      work_package_kind: planned_slice.work_package_kind,
      delivery_repo: redacted_text(planned_slice.delivery_repo),
      target_base_branch: planned_slice.target_base_branch,
      branch_pattern: redacted_text(planned_slice.branch_pattern),
      owned_file_globs: Enum.map(planned_slice.owned_file_globs || [], &redacted_text/1),
      forbidden_file_globs: Enum.map(planned_slice.forbidden_file_globs || [], &redacted_text/1),
      acceptance_criteria: Enum.map(planned_slice.acceptance_criteria || [], &redacted_text/1),
      validation_steps: Enum.map(planned_slice.validation_steps || [], &redacted_text/1),
      review_lanes: planned_slice.review_lanes || [],
      stop_conditions: Enum.map(planned_slice.stop_conditions || [], &redacted_text/1),
      status: planned_slice.status,
      inserted_at: timestamp(planned_slice.inserted_at),
      updated_at: timestamp(planned_slice.updated_at)
    }
    |> CommentProjection.put_counts(CommentProjection.counts_for(Keyword.get(opts, :comment_context), "planned_slice", planned_slice.id))
    |> Map.put(:comments, CommentProjection.comments_for(Keyword.get(opts, :comment_context), "planned_slice", planned_slice.id))
    |> maybe_put_dispatch_linkage(planned_slice, work_package_statuses, opts)
  end

  @doc false
  @spec compact_planned_slice(map()) :: map()
  def compact_planned_slice(payload) when is_map(payload) do
    payload
    |> drop_keys([
      :acceptance_criteria,
      :comments,
      :forbidden_file_globs,
      :owned_file_globs,
      :stop_conditions,
      :validation_steps
    ])
    |> compact_planned_slice_delivery()
  end

  defp compact_planned_slice_delivery(%{delivery: delivery} = payload) when is_map(delivery) do
    Map.put(payload, :delivery, compact_delivery_evidence(delivery))
  end

  defp compact_planned_slice_delivery(payload), do: payload

  @doc false
  @spec compact_delivery_evidence(term()) :: term()
  def compact_delivery_evidence(value) when is_map(value) do
    value
    |> drop_keys([:abandoned_rationale, :no_pr_evidence, :superseded_reason])
    |> Map.new(fn {key, nested} -> {key, compact_delivery_evidence(nested)} end)
  end

  def compact_delivery_evidence(values) when is_list(values), do: Enum.map(values, &compact_delivery_evidence/1)
  def compact_delivery_evidence(value), do: value

  defp drop_keys(map, keys) when is_map(map) do
    Enum.reduce(keys, map, fn key, acc ->
      acc
      |> Map.delete(key)
      |> Map.delete(to_string(key))
    end)
  end

  defp maybe_put_dispatch_linkage(payload, %PlannedSlice{} = planned_slice, work_package_contexts, opts) do
    delivery_slice = Keyword.get(opts, :delivery_slice)
    include_dispatch_linkage? = Keyword.get(opts, :include_dispatch_linkage?, false)
    delivery_opts = [include_delivery_data?: include_dispatch_linkage?]

    payload = DeliverySliceProjection.put_delivery_slice(payload, delivery_slice, delivery_opts)

    if include_dispatch_linkage? do
      work_package_context = Map.get(work_package_contexts, planned_slice.work_package_id)

      payload
      |> Map.put(:work_package_id, planned_slice.work_package_id)
      |> Map.put(:work_package_status, linked_work_package_status(work_package_context))
      |> Map.put(:dispatched_at, timestamp(planned_slice.dispatched_at))
      |> Map.put(:operational_state, planned_slice_operational_state(planned_slice, work_package_context, delivery_slice))
    else
      DeliverySliceProjection.put_delivery_operational_state(payload, delivery_slice)
    end
  end

  @doc false
  @spec planned_slice_work_package_contexts(repo(), [PlannedSlice.t()]) :: {:ok, map()}
  def planned_slice_work_package_contexts(repo, planned_slices) do
    work_package_ids =
      planned_slices
      |> Enum.map(& &1.work_package_id)
      |> Enum.filter(&filled_string?/1)
      |> Enum.uniq()

    if work_package_ids == [] do
      {:ok, %{}}
    else
      work_packages =
        work_package_ids
        |> work_package_context_chunks()
        |> Enum.flat_map(fn work_package_id_chunk ->
          repo.all(
            from(work_package in WorkPackage,
              where: work_package.id in ^work_package_id_chunk
            )
          )
        end)

      {:ok, linked_work_package_contexts(repo, work_packages)}
    end
  end

  defp planned_slice_work_package_contexts_for_grant(repo, planned_slices, %AccessGrant{} = grant) do
    with {:ok, filters} <- work_request_filters_for_grant(repo, grant),
         {:ok, work_package_contexts} <- planned_slice_work_package_contexts(repo, planned_slices) do
      {:ok,
       Map.filter(work_package_contexts, fn
         {_work_package_id, %{work_package: %WorkPackage{} = work_package}} ->
           phase_work_package_matches_filters?(work_package, filters)

         _context ->
           false
       end)}
    end
  end

  @doc false
  @spec linked_work_package_contexts(repo(), [WorkPackage.t()]) :: map()
  def linked_work_package_contexts(_repo, []), do: %{}

  def linked_work_package_contexts(repo, work_packages) do
    work_package_ids = Enum.map(work_packages, & &1.id)
    progress_events_by_id = grouped_progress_events(repo, work_package_ids)
    plan_nodes_by_id = grouped_plan_nodes(repo, work_package_ids)
    artifacts_by_id = grouped_artifacts(repo, work_package_ids)
    findings_by_id = grouped_findings(repo, work_package_ids)
    agent_runs_by_id = grouped_agent_runs(repo, work_package_ids)
    grants_by_id = grouped_access_grants(repo, work_package_ids)
    lineages_by_id = package_lineages(repo, work_packages)
    planned_slice_review_lanes_by_id = grouped_planned_slice_review_lanes(repo, work_package_ids)

    Map.new(work_packages, fn %WorkPackage{} = work_package ->
      progress_events = Map.get(progress_events_by_id, work_package.id, [])
      plan_nodes = Map.get(plan_nodes_by_id, work_package.id, [])
      artifacts = Map.get(artifacts_by_id, work_package.id, [])
      findings = Map.get(findings_by_id, work_package.id, [])
      agent_runs = Map.get(agent_runs_by_id, work_package.id, [])
      grants = Map.get(grants_by_id, work_package.id, [])
      blockers = blockers(progress_events)
      runtime = runtime_summary(agent_runs)
      metadata = metadata(progress_events, artifacts, work_package.id)
      planned_slice_review_lanes = Map.get(planned_slice_review_lanes_by_id, work_package.id)

      readiness_context =
        readiness_context(
          repo,
          work_package,
          plan_nodes,
          progress_events,
          artifacts,
          findings,
          planned_slice_review_lanes
        )

      lineage = Map.get(lineages_by_id, work_package.id, empty_lineage(work_package.id))

      operational_state =
        work_package_operational_state(work_package, %{
          agent_runs: agent_runs,
          progress_events: progress_events,
          blockers: blockers,
          runtime: runtime,
          metadata: metadata,
          readiness_context: readiness_context,
          grants: grants,
          lineage: lineage
        })

      {work_package.id, %{work_package: work_package, card: %{operational_state: operational_state, metadata: metadata}}}
    end)
  end

  defp grouped_progress_events(repo, work_package_ids) do
    chunked_records_by_work_package_id(work_package_ids, fn work_package_id_chunk ->
      repo.all(
        from(progress_event in ProgressEvent,
          where: progress_event.work_package_id in ^work_package_id_chunk,
          order_by: [asc: progress_event.work_package_id, asc: progress_event.sequence, asc: progress_event.inserted_at]
        )
      )
    end)
  end

  defp grouped_plan_nodes(repo, work_package_ids) do
    chunked_records_by_work_package_id(work_package_ids, fn work_package_id_chunk ->
      repo.all(
        from(plan_node in PlanNode,
          where: plan_node.work_package_id in ^work_package_id_chunk,
          order_by: [asc: plan_node.work_package_id, asc: plan_node.position, asc: plan_node.inserted_at]
        )
      )
    end)
  end

  defp grouped_artifacts(repo, work_package_ids) do
    chunked_records_by_work_package_id(work_package_ids, fn work_package_id_chunk ->
      repo.all(
        from(artifact in Artifact,
          where: artifact.work_package_id in ^work_package_id_chunk,
          order_by: [asc: artifact.work_package_id, asc: artifact.sequence, asc: artifact.inserted_at]
        )
      )
    end)
  end

  defp grouped_findings(repo, work_package_ids) do
    chunked_records_by_work_package_id(work_package_ids, fn work_package_id_chunk ->
      repo.all(
        from(finding in Finding,
          where: finding.work_package_id in ^work_package_id_chunk,
          order_by: [asc: finding.work_package_id, asc: finding.sequence, asc: finding.inserted_at]
        )
      )
    end)
  end

  defp grouped_agent_runs(repo, work_package_ids) do
    chunked_records_by_work_package_id(work_package_ids, fn work_package_id_chunk ->
      repo.all(
        from(agent_run in AgentRun,
          where: agent_run.work_package_id in ^work_package_id_chunk,
          order_by: [asc: agent_run.work_package_id, asc: agent_run.started_at, asc: agent_run.inserted_at]
        )
      )
    end)
  end

  defp grouped_access_grants(repo, work_package_ids) do
    chunked_records_by_work_package_id(work_package_ids, fn work_package_id_chunk ->
      repo.all(
        from(access_grant in AccessGrant,
          where: access_grant.work_package_id in ^work_package_id_chunk,
          order_by: [asc: access_grant.work_package_id, asc: access_grant.inserted_at]
        )
      )
    end)
  end

  defp grouped_planned_slice_review_lanes(repo, work_package_ids) do
    {:ok, planned_slices_by_work_package_id} = linked_planned_slices_by_work_package_id(repo, work_package_ids)

    Map.new(planned_slices_by_work_package_id, fn {work_package_id, planned_slice} ->
      {work_package_id, planned_slice_review_lanes(planned_slice)}
    end)
  end

  defp planned_slice_review_lanes(%PlannedSlice{} = planned_slice), do: planned_slice.review_lanes || []
  defp planned_slice_review_lanes(_planned_slice), do: []

  defp chunked_records_by_work_package_id(work_package_ids, list_fun) do
    work_package_ids
    |> work_package_context_chunks()
    |> Enum.flat_map(list_fun)
    |> records_by_work_package_id()
  end

  defp work_package_context_chunks(work_package_ids) do
    work_package_ids
    |> Enum.uniq()
    |> Enum.chunk_every(@work_package_context_chunk_size)
  end

  defp records_by_work_package_id(records), do: Enum.group_by(records, & &1.work_package_id)

  @doc false
  @spec work_request_summary([ClarificationQuestion.t()], [DecisionLogEntry.t()], [PlannedSlice.t()], map()) :: map()
  def work_request_summary(questions, decisions, planned_slices, comment_context) do
    comment_counts = CommentProjection.total_counts(comment_context)

    %{
      open_question_count: Enum.count(questions, &(&1.status == "open")),
      answered_question_count: Enum.count(questions, &(&1.status == "answered")),
      closed_question_count: Enum.count(questions, &(&1.status == "closed")),
      decision_count: length(decisions),
      comment_count: comment_counts.comment_count,
      open_comment_count: comment_counts.open_comment_count,
      planned_slice_count: Enum.count(planned_slices, &(&1.status == "planned")),
      approved_slice_count: Enum.count(planned_slices, &(&1.status == "approved")),
      dispatched_slice_count: Enum.count(planned_slices, &(&1.status == "dispatched")),
      skipped_slice_count: Enum.count(planned_slices, &(&1.status == "skipped"))
    }
  end

  @doc false
  @spec work_request_board_summary([ClarificationQuestion.t()], [PlannedSlice.t()], map()) :: map()
  def work_request_board_summary(questions, planned_slices, comment_context) do
    comment_counts = CommentProjection.total_counts(comment_context)

    %{
      open_question_count: Enum.count(questions, &(&1.status == "open")),
      answered_question_count: Enum.count(questions, &(&1.status == "answered")),
      closed_question_count: Enum.count(questions, &(&1.status == "closed")),
      comment_count: comment_counts.comment_count,
      open_comment_count: comment_counts.open_comment_count,
      planned_slice_count: Enum.count(planned_slices, &(&1.status == "planned")),
      approved_slice_count: Enum.count(planned_slices, &(&1.status == "approved")),
      dispatched_slice_count: Enum.count(planned_slices, &(&1.status == "dispatched")),
      skipped_slice_count: Enum.count(planned_slices, &(&1.status == "skipped"))
    }
  end

  defp plan_node(plan_node) do
    %{
      id: plan_node.id,
      title: redacted_text(plan_node.title),
      body: redacted_text(plan_node.body),
      status: plan_node.status,
      position: plan_node.position,
      created_at: timestamp(plan_node.created_at),
      updated_at: timestamp(plan_node.updated_at)
    }
  end

  defp finding(%Finding{} = finding) do
    %{
      id: finding.id,
      title: redacted_text(finding.title),
      body: redacted_text(finding.body),
      severity: finding.severity,
      sequence: finding.sequence,
      created_at: timestamp(finding.created_at),
      access_grant_id: finding.access_grant_id
    }
  end

  defp progress_event(%ProgressEvent{} = event) do
    %{
      id: event.id,
      summary: redacted_text(event.summary),
      body: redacted_text(event.body),
      status: event.status,
      sequence: event.sequence,
      actor: actor(event),
      agent_run_id: event.agent_run_id,
      payload: redacted_json(event.payload || %{}),
      created_at: timestamp(event.created_at)
    }
  end

  defp timeline_progress_event(%ProgressEvent{} = event) do
    event
    |> progress_event()
    |> Map.merge(%{type: "progress", timeline_order: event.sequence || 0})
  end

  defp timeline_finding(%Finding{} = finding) do
    finding
    |> finding()
    |> Map.merge(%{type: "finding", timeline_order: finding.sequence || 0})
  end

  defp timeline_sort_key(%{created_at: created_at, timeline_order: order, id: id}) do
    {timestamp_sort_value(created_at), order || 0, id || ""}
  end

  defp artifact(%Artifact{} = artifact) do
    %{
      id: artifact.id,
      path: redacted_text(artifact.path),
      title: redacted_text(artifact.title),
      kind: artifact.kind,
      uri: redacted_uri(artifact.uri),
      sequence: artifact.sequence,
      created_at: timestamp(artifact.created_at)
    }
  end

  defp grant(%AccessGrant{} = grant) do
    %{
      id: grant.id,
      work_package_id: grant.work_package_id,
      phase_id: grant.phase_id,
      display_key: grant.display_key,
      grant_role: grant.grant_role,
      capabilities: grant.capabilities || [],
      expires_at: timestamp(grant.expires_at),
      revoked_at: timestamp(grant.revoked_at),
      claimed_at: timestamp(grant.claimed_at),
      claimed_by: grant.claimed_by,
      status: grant_status(grant)
    }
  end

  defp phase(%Phase{} = phase) do
    %{
      id: phase.id,
      title: redacted_text(phase.title),
      description: redacted_text(phase.description),
      status: phase.status,
      inserted_at: timestamp(phase.inserted_at),
      updated_at: timestamp(phase.updated_at)
    }
  end

  defp agent_run(%AgentRun{} = run) do
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

  defp runtime_summary(agent_runs) do
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

  defp runtime_state(%AgentRun{status: "starting"}), do: "queued"
  defp runtime_state(%AgentRun{status: status}) when status in ["running", "retrying"], do: "active"
  defp runtime_state(%AgentRun{status: "stopped"}), do: "stopped"
  defp runtime_state(%AgentRun{status: status}) when status in ["completed", "failed"], do: "terminal"
  defp runtime_state(%AgentRun{}), do: "unknown"

  defp latest_active_agent_run(agent_runs) do
    agent_runs
    |> latest_active_run()
    |> case do
      %AgentRun{} = run -> agent_run(run)
      nil -> nil
    end
  end

  defp latest_active_run(agent_runs) do
    agent_runs
    |> Enum.filter(&(runtime_state(&1) in ["active", "queued"] and not stale_agent_run?(&1)))
    |> List.last()
  end

  defp latest_progress_at(progress_events) do
    progress_events
    |> Enum.max_by(&timestamp_sort_value(&1.created_at), fn -> nil end)
    |> case do
      %ProgressEvent{created_at: created_at} -> timestamp(created_at)
      nil -> nil
    end
  end

  defp plan_summary(plan_nodes) do
    total = length(plan_nodes)
    completed = Enum.count(plan_nodes, &(&1.status in ["done", "completed", "skipped"]))

    %{
      total_count: total,
      completed_count: completed,
      open_count: max(total - completed, 0)
    }
  end

  defp work_package_operational_state(%WorkPackage{} = work_package, context) do
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

  defp planned_slice_operational_state(%PlannedSlice{} = planned_slice, work_package_context, delivery_slice, delivery_state_opts \\ []) do
    base_state = base_planned_slice_operational_state(planned_slice, work_package_context)

    case DeliverySliceProjection.primary_operational_state(delivery_slice, delivery_state_opts) do
      nil -> base_state
      operational_state -> delivery_operational_state_overlay(base_state, operational_state)
    end
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

  defp linked_work_package_status(%{work_package: %WorkPackage{status: status}}), do: status
  defp linked_work_package_status(_work_package_context), do: nil

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

  defp work_package_started?(
         status,
         has_active_worker,
         agent_runs,
         runtime,
         has_meaningful_progress,
         metadata
       ) do
    status in @started_package_statuses or
      has_active_worker or
      agent_run_activity?(agent_runs) or
      runtime_activity?(runtime) or
      has_meaningful_progress or
      metadata_activity?(metadata)
  end

  defp operational_activity_fields(activity) do
    Map.take(activity, [:has_started, :has_active_worker, :has_prepared_worktree, :last_activity_at, :is_stale])
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
    Enum.any?([:branch, :pr, :review_progress, :review_package, :review_suite_result], &present_metadata_value?(safe_map_get(metadata, &1)))
  end

  defp review_activity?(metadata) do
    Enum.any?([:review_progress, :review_package, :review_suite_result], &present_metadata_value?(safe_map_get(metadata, &1)))
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

  defp alert_indicators(repo, %State{} = state, runtime) do
    state
    |> readiness_context(repo, length(state.artifacts), length(state.findings))
    |> alert_indicators(blockers(state.progress_events), runtime)
  end

  defp alert_indicators(readiness_context, blockers, runtime) do
    [
      blocker_indicator(readiness_context.work_package, blockers),
      stale_heartbeat_indicator(runtime),
      failed_run_indicator(runtime),
      missing_readiness_indicator(readiness_context),
      scope_drift_indicator(readiness_context)
    ]
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

  defp readiness_context(%State{} = state, repo, _artifact_count, _finding_count) do
    readiness_context(
      repo,
      state.work_package,
      state.plan_nodes,
      state.progress_events,
      state.artifacts,
      state.findings
    )
  end

  defp readiness_context(repo, %WorkPackage{} = work_package, plan_nodes, progress_events, artifacts, findings) do
    readiness_context(repo, work_package, plan_nodes, progress_events, artifacts, findings, :load)
  end

  defp readiness_context(
         repo,
         %WorkPackage{} = work_package,
         plan_nodes,
         progress_events,
         artifacts,
         findings,
         planned_slice_review_lanes
       ) do
    %{
      repo: repo,
      work_package: work_package,
      plan_nodes: plan_nodes,
      progress_events: chronological_progress_events(progress_events),
      artifacts: artifacts,
      findings: findings,
      planned_slice_review_lanes: planned_slice_review_lanes,
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

  defp missing_readiness_gates(reasons) do
    reasons
    |> Enum.map(&Map.fetch!(&1, "gate"))
    |> Enum.uniq()
  end

  defp readiness_failure_reasons(%{work_package: %WorkPackage{}} = context) do
    required_review_lanes = required_review_lanes(context)

    [
      {active_blocker?(context.progress_events), "no_active_blockers"},
      {incomplete_plan?(context), "plan_complete"},
      {acceptance_missing?(context), "acceptance_criteria_met"},
      {tests_missing?(context), "tests_passed"},
      {merge_metadata_missing?(context, "branch"), "branch_attached"},
      {merge_metadata_missing?(context, "pr"), "pr_attached"},
      {current_pr_state_missing?(context), "current_pr_state"},
      {review_suite_result_missing?(context), "review_suite_result"},
      {ScopeGuard.missing?(context.work_package, context.progress_events), @scope_guard_gate},
      {review_package_missing?(context, required_review_lanes), "review_package_submitted"},
      {review_artifacts_missing?(context, required_review_lanes), "review_artifacts_attached"},
      {review_lanes_missing?(context, required_review_lanes), "review_lanes_complete"},
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
  defp readiness_failure_message("review_suite_result"), do: "Current-head review-suite result evidence is missing."
  defp readiness_failure_message("review_package_submitted"), do: "Current-head review package is missing."
  defp readiness_failure_message("review_artifacts_attached"), do: "Current-head review artifacts are missing."
  defp readiness_failure_message("review_lanes_complete"), do: "Required review profiles are not green."
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

  defp review_suite_result_missing?(context) do
    required_gate?(context.work_package, "review_suite_result") and
      not review_suite_result_present?(context.progress_events, context.artifacts, context.work_package.id, review_head_sha_for_readiness(context))
  end

  defp review_suite_result_present?(_progress_events, _artifacts, _work_package_id, nil), do: false

  defp review_suite_result_present?(progress_events, artifacts, work_package_id, readiness_head_sha) do
    case latest_review_suite_result_event(progress_events, work_package_id, readiness_head_sha) do
      %ProgressEvent{payload: payload} ->
        valid_review_suite_result_payload?(payload, work_package_id, readiness_head_sha) and
          persisted_review_suite_artifact?(artifacts, work_package_id, Map.fetch!(payload, "head_sha"))

      nil ->
        false
    end
  end

  defp review_package_missing?(context, required_lanes) do
    readiness_head_sha = review_head_sha_for_readiness(context)

    merge_required?(context.work_package) and review_lanes_required?(required_lanes) and
      current_head_review_package_events(context.progress_events, readiness_head_sha) == []
  end

  defp review_artifacts_missing?(context, required_lanes) do
    merge_required?(context.work_package) and review_lanes_required?(required_lanes) and
      not review_artifacts_present?(context, required_lanes)
  end

  defp review_lanes_missing?(context, required_lanes) do
    review_lanes_required?(required_lanes) and not review_lanes_present?(context, required_lanes)
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

  defp required_gate?(%WorkPackage{} = work_package, gate) do
    case policy_for(work_package) do
      {:ok, policy} -> gate in Map.get(policy, :required_gates, [])
      {:error, _reason} -> false
    end
  end

  defp required_review_lanes(%{work_package: %WorkPackage{} = work_package} = context) do
    case Map.get(context, :planned_slice_review_lanes, :load) do
      :load ->
        case ReviewLanes.required(Map.get(context, :repo), work_package) do
          {:ok, {required_lanes, _warnings}} -> required_lanes
          {:error, _reason} -> ReviewLanes.policy_required(work_package)
        end

      planned_slice_review_lanes ->
        {required_lanes, _warnings} =
          ReviewLanes.required_from_planned_slice_lanes(work_package, planned_slice_review_lanes)

        required_lanes
    end
  end

  defp policy_for(%WorkPackage{} = work_package), do: LifecycleService.policy_for(work_package)

  defp review_lanes_required?(required_lanes), do: required_lanes != []

  defp merge_required?(%WorkPackage{} = work_package) do
    case policy_for(work_package) do
      {:ok, policy} ->
        required_gates = Map.get(policy, :required_gates, [])
        Enum.any?(@merge_required_gates, &(&1 in required_gates))

      {:error, _reason} ->
        work_package.kind in @runtime_merge_required_kinds
    end
  end

  defp pr_required?(%WorkPackage{} = work_package) do
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

  defp review_lanes_present?(context, required_lanes) do
    if merge_required?(context.work_package) do
      review_package_lanes_present?(
        context.progress_events,
        required_lanes,
        review_head_sha_for_readiness(context)
      ) or review_suite_result_lanes_present?(context, required_lanes)
    else
      progress_events = current_branch_progress_events(context.progress_events)

      review_package_lanes_present?(progress_events, required_lanes, review_head_sha_for_readiness(context)) or
        review_suite_result_lanes_present?(context, required_lanes) or
        progress_review_lanes_present?(progress_events, required_lanes)
    end
  end

  defp review_package_lanes_present?(progress_events, required_lanes, readiness_head_sha) do
    latest_verdicts =
      case latest_review_package_event(progress_events, readiness_head_sha) do
        %ProgressEvent{} = event ->
          event
          |> review_package_reviews(readiness_head_sha)
          |> Enum.reduce(%{}, fn review, verdicts ->
            Map.put(verdicts, ReviewProfiles.normalize_profile(Map.get(review, "lane")), Map.get(review, "verdict"))
          end)

        nil ->
          %{}
      end

    Enum.all?(required_lanes, &ReviewProfiles.profile_verdicts_pass?(&1, latest_verdicts))
  end

  defp review_suite_result_lanes_present?(context, required_lanes) do
    readiness_head_sha = review_head_sha_for_readiness(context)

    payloads =
      context.progress_events
      |> MetadataProjection.current_head_review_suite_result_events(context.work_package.id, readiness_head_sha)
      |> Enum.map(& &1.payload)
      |> Enum.filter(
        &(review_suite_result_payload_in_scope?(&1, context.work_package.id, readiness_head_sha) and
            persisted_review_suite_artifact?(context.artifacts, context.work_package.id, Map.fetch!(&1, "head_sha")))
      )

    payloads != [] and
      Enum.all?(required_lanes, &ReviewProfiles.review_suite_payloads_satisfy_required_profile?(payloads, &1))
  end

  defp progress_review_lanes_present?(progress_events, required_lanes) do
    Enum.all?(required_lanes, &progress_review_lane_present?(progress_events, &1))
  end

  defp progress_review_lane_present?(progress_events, required_lane) do
    satisfying_profiles = ReviewProfiles.satisfying_profiles(required_lane)

    latest_statuses =
      satisfying_profiles
      |> Enum.map(&{&1, latest_generic_progress_status(progress_events, ReviewProfiles.statuses(&1))})
      |> Enum.reject(fn {_profile, status} -> is_nil(status) end)

    latest_statuses != [] and
      Enum.all?(latest_statuses, fn {profile, status} -> status in ReviewProfiles.green_statuses(profile) end)
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

  defp review_artifacts_present?(context, required_lanes) do
    current_head_sha = latest_current_head_sha(context.progress_events)
    artifact_references = current_head_review_artifact_references(context.progress_events, current_head_sha)

    review_package_artifacts_present =
      artifact_references != [] and
        Enum.all?(artifact_references, fn {path, artifact_head_sha} ->
          persisted_review_artifact?(context.artifacts, context.work_package.id, artifact_head_sha, path)
        end)

    review_package_artifacts_present or
      review_suite_result_lanes_present?(context, required_lanes)
  end

  defp current_head_review_artifact_references(progress_events, current_head_sha) do
    case latest_review_package_event(progress_events, current_head_sha) do
      %ProgressEvent{} = event -> review_package_artifact_references(event, current_head_sha)
      nil -> []
    end
  end

  defp review_package_artifact_paths(%ProgressEvent{payload: payload}, readiness_head_sha) when is_map(payload) do
    artifacts = Map.get(payload, "artifacts")

    if is_list(artifacts) and review_head_matches?(payload, readiness_head_sha) do
      Enum.filter(artifacts, &(is_binary(&1) and String.trim(&1) != ""))
    else
      []
    end
  end

  defp review_package_artifact_paths(%ProgressEvent{}, _readiness_head_sha), do: []

  defp review_package_artifact_references(%ProgressEvent{payload: payload} = event, readiness_head_sha) when is_map(payload) do
    event
    |> review_package_artifact_paths(readiness_head_sha)
    |> Enum.map(&{&1, Map.get(payload, "head_sha")})
  end

  defp review_package_artifact_references(%ProgressEvent{}, _readiness_head_sha), do: []

  defp persisted_review_artifact?(artifacts, work_package_id, head_sha, path), do: MetadataProjection.persisted_review_artifact?(artifacts, work_package_id, head_sha, path)

  defp latest_review_suite_result_event(progress_events, work_package_id, readiness_head_sha),
    do: MetadataProjection.latest_review_suite_result_event(progress_events, work_package_id, readiness_head_sha)

  defp valid_review_suite_result_payload?(payload, work_package_id, readiness_head_sha),
    do: MetadataProjection.valid_review_suite_result_payload?(payload, work_package_id, readiness_head_sha)

  defp review_suite_result_payload_in_scope?(payload, work_package_id, readiness_head_sha),
    do: MetadataProjection.review_suite_result_payload_in_scope?(payload, work_package_id, readiness_head_sha)

  defp persisted_review_suite_artifact?(artifacts, work_package_id, head_sha),
    do: MetadataProjection.persisted_review_suite_artifact?(artifacts, work_package_id, head_sha)

  defp recommendation_artifact_recorded?(artifacts, work_package_id), do: MetadataProjection.recommendation_artifact_recorded?(artifacts, work_package_id)
  defp review_package_reviews(event, readiness_head_sha), do: MetadataProjection.review_package_reviews(event, readiness_head_sha)
  @doc false
  @spec filled_string?(term()) :: boolean()
  def filled_string?(value), do: MetadataProjection.filled_string?(value)
  defp review_head_matches?(payload, readiness_head_sha), do: MetadataProjection.review_head_matches?(payload, readiness_head_sha)

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

  defp latest_current_head_sha(progress_events), do: MetadataProjection.latest_current_head_sha(progress_events)
  defp metadata_present?(progress_events, type, head_sha), do: MetadataProjection.metadata_present?(progress_events, type, head_sha)
  defp current_pr_state_present?(progress_events, head_sha), do: MetadataProjection.current_pr_state_present?(progress_events, head_sha)
  defp normalized_status(status), do: MetadataProjection.normalized_status(status)
  defp metadata(progress_events, artifacts, work_package_id), do: MetadataProjection.metadata(progress_events, artifacts, work_package_id)
  defp package_lineage(repo, work_package_id), do: MetadataProjection.package_lineage(repo, work_package_id)
  defp package_lineages(repo, work_packages), do: MetadataProjection.package_lineages(repo, work_packages)
  defp empty_lineage(work_package_id), do: MetadataProjection.empty_lineage(work_package_id)

  defp blockers(progress_events), do: BlockerProjection.blockers(progress_events)
  defp chronological_progress_events(progress_events), do: MetadataProjection.chronological_progress_events(progress_events)
  defp payload_type?(event, type, source_tool), do: MetadataProjection.payload_type?(event, type, source_tool)
  defp blocker_event?(event), do: BlockerProjection.blocker_event?(event)
  defp actor(event), do: BlockerProjection.actor(event)
  defp grant_status(%AccessGrant{revoked_at: %DateTime{}}), do: "revoked"

  defp grant_status(%AccessGrant{expires_at: %DateTime{} = expires_at} = grant) do
    if DateTime.compare(expires_at, DateTime.utc_now(:microsecond)) != :gt do
      "expired"
    else
      claimed_grant_status(grant)
    end
  end

  defp grant_status(%AccessGrant{} = grant), do: claimed_grant_status(grant)

  defp claimed_grant_status(%AccessGrant{claimed_at: nil}), do: "unclaimed"
  defp claimed_grant_status(%AccessGrant{claimed_by: nil}), do: "unclaimed"
  defp claimed_grant_status(%AccessGrant{}), do: "active"

  defp active_grant?(%AccessGrant{} = grant), do: grant_status(grant) == "active"

  defp normalize_blocker_id(value) when is_binary(value), do: String.trim(value)
  defp normalize_blocker_id(value), do: to_string(value)

  @doc false
  @spec redacted_json(term()) :: term()
  def redacted_json(value), do: Sanitizer.redacted_json(value)
  defp redacted_text(value), do: Sanitizer.redacted_text(value)
  defp redacted_uri(value), do: Sanitizer.redacted_uri(value)
  defp timestamp_sort_value(value), do: Sanitizer.timestamp_sort_value(value)
  defp timestamp(value), do: Sanitizer.timestamp(value)
end
