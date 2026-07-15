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
    OperationalProjection,
    Sanitizer,
    SoloSessionProjection,
    WorkRequestCards,
    WorkRequestDetails
  }

  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Repository, as: GuidanceRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Artifact
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Finding
  alias SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.Planning.State
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DecisionLogEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.DeliveryBoard
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @ready_statuses ["ready_for_merge", "ready_for_human_merge", "ready_for_architect_merge"]
  @dropped_child_statuses ["abandoned"]
  @non_open_child_statuses ["merged_into_phase", "closed", "abandoned"]
  @work_package_context_chunk_size 500
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

  @doc false
  @spec work_request_sections(repo(), keyword()) ::
          {:ok, %{active: map(), archived: map()}} | {:error, dashboard_error()}
  def work_request_sections(repo, opts) when is_atom(repo) and is_list(opts) do
    safe_read(fn ->
      with {:ok, work_requests} <- WorkRequestRepository.list(repo, %{include_archived: true}),
           {:ok, repo_identity_catalog} <- repo_identity_catalog_from_repo(repo, opts, Enum.map(work_requests, & &1.repo)),
           {:ok, cards} <- work_request_cards(repo, ordered_work_requests(work_requests), Keyword.put(opts, :repo_identity_catalog, repo_identity_catalog)) do
        active_cards = visible_work_request_cards(cards)
        archived_cards = Enum.filter(cards, &(not is_nil(&1.archived_at)))

        {:ok,
         %{
           active: %{work_requests: active_cards, total_count: length(active_cards)},
           archived: %{work_requests: archived_cards, total_count: length(archived_cards)}
         }}
      end
    end)
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
    SoloSessionProjection.list(repo, filters, opts)
  end

  @spec solo_session_detail(repo(), String.t()) :: {:ok, map()} | {:error, dashboard_error()}
  def solo_session_detail(repo, solo_session_id) when is_atom(repo) and is_binary(solo_session_id) do
    solo_session_detail(repo, solo_session_id, [])
  end

  @spec solo_session_detail(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def solo_session_detail(repo, solo_session_id, opts) when is_atom(repo) and is_binary(solo_session_id) and is_list(opts) do
    SoloSessionProjection.detail(repo, solo_session_id, opts)
  end

  @spec solo_session_repos(repo()) :: {:ok, [String.t()]} | {:error, dashboard_error()}
  def solo_session_repos(repo) when is_atom(repo) do
    SoloSessionProjection.repos(repo)
  end

  @spec solo_session_streams(repo()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def solo_session_streams(repo) when is_atom(repo) do
    solo_session_streams(repo, [])
  end

  @spec solo_session_streams(repo(), keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def solo_session_streams(repo, opts) when is_atom(repo) and is_list(opts) do
    SoloSessionProjection.streams(repo, opts)
  end

  @spec solo_session_count(repo()) :: {:ok, non_neg_integer()} | {:error, dashboard_error()}
  def solo_session_count(repo) when is_atom(repo) do
    SoloSessionProjection.count(repo)
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
        blockers = OperationalProjection.blockers(state.progress_events)
        summary = summary(state, grants, agent_runs, blockers, guidance_requests, comment_context)

        {:ok,
         %{
           work_package:
             state.work_package
             |> work_package_detail(repo_identity_catalog)
             |> CommentProjection.put_counts(CommentProjection.counts_for(comment_context, "work_package", work_package_id)),
           lineage: OperationalProjection.package_lineage(repo, work_package_id),
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
           metadata:
             OperationalProjection.metadata(
               state.progress_events,
               state.artifacts,
               state.work_package.id,
               state.work_package.review_requirement
             ),
           alert_indicators: OperationalProjection.alert_indicators(repo, state, summary.runtime)
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
        {:ok, %{work_package_id: work_package_id, blockers: OperationalProjection.blockers(state.progress_events)}}
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
      card_context(repo, work_package, OperationalProjection.package_lineage(repo, work_package.id), repo_identity_catalog)
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
      blockers = OperationalProjection.blockers(progress_events)
      runtime = OperationalProjection.runtime_summary(agent_runs)

      readiness_context =
        OperationalProjection.readiness_context(
          repo,
          work_package,
          status_summary.plan_nodes,
          progress_events,
          artifacts,
          findings
        )

      metadata = OperationalProjection.metadata(progress_events, artifacts, work_package.id, work_package.review_requirement)

      operational_state =
        OperationalProjection.work_package_operational_state(work_package, %{
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
             active_agent_run: OperationalProjection.latest_active_agent_run(agent_runs),
             runtime: runtime,
             latest_progress_at: latest_progress_at(progress_events),
             active_blocker_count: Enum.count(blockers, & &1.active),
             active_blockers: active_blockers(blockers),
             artifact_count: status_summary.artifact_count,
             finding_count: status_summary.finding_count,
             plan: OperationalProjection.plan_summary(status_summary.plan_nodes),
             metadata: metadata,
             lineage: lineage,
             operational_state: operational_state,
             alert_indicators: OperationalProjection.alert_indicators(readiness_context, blockers, runtime),
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
    merge_required?(work_package) or required_gate?(work_package, "recommendation_artifact_recorded")
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
    lineages_by_id = OperationalProjection.package_lineages(repo, work_packages)

    work_packages
    |> Enum.map(&card_context(repo, &1, Map.get(lineages_by_id, &1.id, OperationalProjection.empty_lineage(&1.id)), repo_identity_catalog))
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

  defp work_request_cards(repo, work_requests, opts), do: WorkRequestCards.cards(repo, work_requests, opts)
  defp visible_work_request_cards(cards), do: WorkRequestCards.visible_cards(cards)
  defp ordered_work_requests(work_requests), do: WorkRequestCards.ordered_work_requests(work_requests)

  @doc false
  @spec ordered_sequence_records([struct()]) :: [struct()]
  def ordered_sequence_records(records) do
    Enum.sort_by(records, fn record ->
      {Map.get(record, :sequence) || 0, Map.get(record, :id) || ""}
    end)
  end

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
    runtime = OperationalProjection.runtime_summary(agent_runs)
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
      plan: OperationalProjection.plan_summary(state.plan_nodes)
    }
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

  @doc false
  @spec visible_planned_slices([PlannedSlice.t()], map() | nil) :: [PlannedSlice.t()]
  def visible_planned_slices(planned_slices, delivery_board), do: WorkRequestCards.visible_planned_slices(planned_slices, delivery_board)

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
    WorkRequestCards.work_request_payload(
      work_request,
      questions,
      planned_slices,
      work_package_contexts,
      repo_identity_catalog,
      comment_context,
      opts
    )
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
      review: redacted_json(planned_slice.review_requirement),
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
      |> Map.put(:operational_state, OperationalProjection.planned_slice_operational_state(planned_slice, work_package_context, delivery_slice))
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
    lineages_by_id = OperationalProjection.package_lineages(repo, work_packages)

    Map.new(work_packages, fn %WorkPackage{} = work_package ->
      progress_events = Map.get(progress_events_by_id, work_package.id, [])
      plan_nodes = Map.get(plan_nodes_by_id, work_package.id, [])
      artifacts = Map.get(artifacts_by_id, work_package.id, [])
      findings = Map.get(findings_by_id, work_package.id, [])
      agent_runs = Map.get(agent_runs_by_id, work_package.id, [])
      grants = Map.get(grants_by_id, work_package.id, [])
      blockers = OperationalProjection.blockers(progress_events)
      runtime = OperationalProjection.runtime_summary(agent_runs)
      metadata = OperationalProjection.metadata(progress_events, artifacts, work_package.id, work_package.review_requirement)

      readiness_context =
        OperationalProjection.readiness_context(
          repo,
          work_package,
          plan_nodes,
          progress_events,
          artifacts,
          findings,
          work_package.review_requirement
        )

      lineage = Map.get(lineages_by_id, work_package.id, OperationalProjection.empty_lineage(work_package.id))

      operational_state =
        OperationalProjection.work_package_operational_state(work_package, %{
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

  @spec stale_agent_run?(AgentRun.t()) :: boolean()
  def stale_agent_run?(%AgentRun{} = run), do: OperationalProjection.stale_agent_run?(run)

  @spec stale_agent_run?(AgentRun.t(), DateTime.t(), non_neg_integer()) :: boolean()
  def stale_agent_run?(%AgentRun{} = run, %DateTime{} = now, threshold_seconds), do: OperationalProjection.stale_agent_run?(run, now, threshold_seconds)

  defp agent_run(%AgentRun{} = run), do: OperationalProjection.agent_run(run)

  @doc false
  @spec missing_readiness_evidence(map()) :: [String.t()]
  def missing_readiness_evidence(context), do: OperationalProjection.missing_readiness_evidence(context)

  @doc false
  @spec filled_string?(term()) :: boolean()
  def filled_string?(value), do: MetadataProjection.filled_string?(value)

  defp latest_progress_at(progress_events) do
    progress_events
    |> Enum.max_by(&timestamp_sort_value(&1.created_at), fn -> nil end)
    |> case do
      %ProgressEvent{created_at: created_at} -> timestamp(created_at)
      nil -> nil
    end
  end

  defp active_blockers(blockers), do: Enum.filter(blockers, & &1.active)

  defp merge_required?(%WorkPackage{} = work_package), do: OperationalProjection.merge_required?(work_package)
  defp pr_required?(%WorkPackage{} = work_package), do: OperationalProjection.pr_required?(work_package)
  defp required_gate?(%WorkPackage{} = work_package, gate), do: OperationalProjection.required_gate?(work_package, gate)

  defp linked_work_package_status(%{work_package: %WorkPackage{status: status}}), do: status
  defp linked_work_package_status(_work_package_context), do: nil

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

  @doc false
  @spec redacted_json(term()) :: term()
  def redacted_json(value), do: Sanitizer.redacted_json(value)
  defp redacted_text(value), do: Sanitizer.redacted_text(value)
  defp redacted_uri(value), do: Sanitizer.redacted_uri(value)
  defp timestamp_sort_value(value), do: Sanitizer.timestamp_sort_value(value)
  defp timestamp(value), do: Sanitizer.timestamp(value)
end
