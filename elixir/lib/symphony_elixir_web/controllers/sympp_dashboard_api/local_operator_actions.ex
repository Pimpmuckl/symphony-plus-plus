defmodule SymphonyElixirWeb.SymppDashboardApi.LocalOperatorActions do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Comments.Comment
  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.GitHub.DefaultClient
  alias SymphonyElixir.SymphonyPlusPlus.HumanDecisionPrompt
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ClarificationQuestion
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixirWeb.SymppDashboardApi.Runtime, as: DashboardRuntime

  import Ecto.Query, only: [from: 2]

  @local_operator_worker "local-operator-worker"
  @local_operator_actor "local-operator"
  @local_operator_nonmergeable_terminal_package_statuses ["merged_into_phase", "closed", "abandoned"]
  @local_operator_noncloseable_terminal_package_statuses ["merged", "merged_into_phase", "abandoned"]
  @local_operator_hideable_package_statuses ["merged", "merged_into_phase", "closed", "abandoned"]

  @spec local_operator_work_request_state(map()) :: {:ok, String.t()} | {:error, atom()}
  def local_operator_work_request_state(params) do
    case text_param(params, "state") || text_param(params, "status") do
      "completed" -> {:ok, "completed"}
      _state -> {:error, :invalid_status}
    end
  end

  @spec local_operator_work_package_status(map()) :: {:ok, atom()} | {:error, atom()}
  def local_operator_work_package_status(params) do
    case text_param(params, "status") do
      "merged" -> {:ok, :merged}
      "merged_and_archive" -> {:ok, :merged_and_archive}
      "closed_and_archive" -> {:ok, :closed_and_archive}
      "completed_no_pr" -> {:ok, :completed_no_pr}
      "unblock" -> {:ok, :unblock}
      _status -> {:error, :invalid_status}
    end
  end

  @spec change_work_package_for_local_operator(module(), String.t(), atom(), map()) ::
          {:ok, WorkPackage.t()} | {:error, term()}
  def change_work_package_for_local_operator(repo, work_package_id, :merged, _params) do
    mark_work_package_merged_and_refresh_for_local_operator(repo, work_package_id)
  end

  def change_work_package_for_local_operator(repo, work_package_id, :merged_and_archive, _params) do
    local_operator_transaction(repo, fn ->
      with {:ok, work_package} <- mark_work_package_merged_for_local_operator(repo, work_package_id),
           :ok <- refresh_work_requests_for_work_package(repo, work_package.id),
           {:ok, _hidden_package} <- hide_work_package_for_local_operator_in_transaction(repo, work_package) do
        {:ok, work_package}
      end
    end)
  end

  def change_work_package_for_local_operator(repo, work_package_id, :closed_and_archive, _params) do
    local_operator_transaction(repo, fn ->
      with {:ok, work_package} <- close_work_package_for_local_operator(repo, work_package_id),
           {:ok, _hidden_package} <- hide_work_package_for_local_operator_in_transaction(repo, work_package) do
        {:ok, work_package}
      end
    end)
  end

  def change_work_package_for_local_operator(repo, work_package_id, :completed_no_pr, params) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id),
         :ok <- require_closeable_work_package(work_package),
         {:ok, no_pr_evidence} <- required_no_pr_evidence(params),
         {:ok, work_package} <- require_work_request_package(work_package),
         {:ok, _delivery} <-
           WorkRequestService.record_work_package_delivery(repo, work_package.work_request_id, work_package.id, %{
             outcome: "completed_no_pr",
             idempotency_key: completed_no_pr_idempotency_key(work_package.id),
             no_pr_evidence: no_pr_evidence,
             recorded_by: @local_operator_actor
           }) do
      WorkPackageRepository.get(repo, work_package_id)
    end
  end

  def change_work_package_for_local_operator(repo, work_package_id, :unblock, _params) do
    WorkPackageRepository.update_status(repo, work_package_id, "blocked", "ready_for_worker")
  end

  defp mark_work_package_merged_and_refresh_for_local_operator(repo, work_package_id) do
    local_operator_transaction(repo, fn ->
      with {:ok, work_package} <- mark_work_package_merged_for_local_operator(repo, work_package_id),
           :ok <- refresh_work_requests_for_work_package(repo, work_package.id) do
        {:ok, work_package}
      end
    end)
  end

  defp mark_work_package_merged_for_local_operator(repo, work_package_id) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
      case work_package.status do
        "merged" ->
          {:ok, work_package}

        status when status in @local_operator_nonmergeable_terminal_package_statuses ->
          {:error, :invalid_status}

        status when is_binary(status) ->
          WorkPackageRepository.update_status(repo, work_package.id, status, "merged")

        _status ->
          {:error, :invalid_status}
      end
    end
  end

  defp close_work_package_for_local_operator(repo, work_package_id) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
      case work_package.status do
        "closed" ->
          {:ok, work_package}

        status when status in @local_operator_noncloseable_terminal_package_statuses ->
          {:error, :invalid_status}

        status when is_binary(status) ->
          WorkPackageRepository.update_status(repo, work_package.id, status, "closed")

        _status ->
          {:error, :invalid_status}
      end
    end
  end

  defp require_closeable_work_package(%WorkPackage{status: status})
       when status in @local_operator_noncloseable_terminal_package_statuses do
    {:error, :invalid_status}
  end

  defp require_closeable_work_package(%WorkPackage{status: status}) when is_binary(status), do: :ok
  defp require_closeable_work_package(%WorkPackage{}), do: {:error, :invalid_status}

  @spec hide_work_package_for_local_operator(module(), String.t()) :: {:ok, WorkPackage.t()} | {:error, term()}
  def hide_work_package_for_local_operator(repo, work_package_id) do
    local_operator_transaction(repo, fn ->
      with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
        hide_work_package_for_local_operator_in_transaction(repo, work_package)
      end
    end)
  end

  defp hide_work_package_for_local_operator_in_transaction(repo, %WorkPackage{} = work_package) do
    with :ok <- require_hideable_work_package(work_package),
         :ok <- require_direct_work_package(work_package),
         {:ok, _settings} <- append_hidden_work_package_id_for_local_operator(repo, work_package.id) do
      {:ok, work_package}
    end
  end

  defp require_hideable_work_package(%WorkPackage{status: status}) do
    if status in @local_operator_hideable_package_statuses, do: :ok, else: {:error, :not_delivered}
  end

  defp require_direct_work_package(%WorkPackage{work_request_id: work_request_id})
       when work_request_id in [nil, ""],
       do: :ok

  defp require_direct_work_package(%WorkPackage{}), do: {:error, :work_request_package}

  defp require_work_request_package(%WorkPackage{work_request_id: work_request_id} = work_package)
       when is_binary(work_request_id) and work_request_id != "",
       do: {:ok, work_package}

  defp require_work_request_package(%WorkPackage{}), do: {:error, :work_request_package_required}

  defp required_no_pr_evidence(params) do
    case text_param(params, "no_pr_evidence") do
      nil -> {:error, :missing_no_pr_evidence}
      evidence -> {:ok, evidence}
    end
  end

  defp completed_no_pr_idempotency_key(work_package_id), do: "local-operator-completed-no-pr:#{work_package_id}"

  @spec clear_work_package_blocker_for_local_operator(module(), String.t(), term(), map()) ::
          {:ok, term()} | {:error, term()}
  def clear_work_package_blocker_for_local_operator(repo, work_package_id, blocker_id, params) do
    blocker_id = String.trim(to_string(blocker_id || ""))

    with true <- valid_package_route_id?(work_package_id),
         true <- blocker_id != "",
         {:ok, _work_package} <- WorkPackageRepository.get(repo, work_package_id),
         {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package_id),
         {:ok, blocker} <- active_blocker(progress_events, blocker_id) do
      PlanningRepository.append_progress_event(repo, %{
        work_package_id: work_package_id,
        summary: "Cleared blocker: #{blocker.summary || blocker.id}",
        body: text_param(params, "resolution") || "Cleared by local operator from the blocker detail modal.",
        status: "resolved",
        idempotency_key: "local-operator-clear-blocker:#{work_package_id}:#{blocker.id}:#{blocker.event_id}",
        payload: %{
          type: "blocker",
          source_tool: "resolve_blocker",
          blocker_id: blocker.id,
          resolution: text_param(params, "resolution") || "Cleared by local operator.",
          active: false
        }
      })
    else
      false -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp valid_package_route_id?(work_package_id) when is_binary(work_package_id) do
    String.trim(work_package_id) != "" and not String.contains?(work_package_id, ["\0", "\n", "\r", "\t"])
  end

  defp valid_package_route_id?(_work_package_id), do: false

  defp active_blocker(progress_events, blocker_id) do
    progress_events
    |> BlockerProjection.blockers()
    |> Enum.find(&(&1.id == blocker_id and &1.active))
    |> case do
      nil -> {:error, :not_found}
      blocker -> {:ok, blocker}
    end
  end

  defp append_hidden_work_package_id_for_local_operator(_repo, work_package_id)
       when not is_binary(work_package_id) or byte_size(work_package_id) == 0 do
    {:error, :not_found}
  end

  defp append_hidden_work_package_id_for_local_operator(repo, work_package_id) do
    now = DateTime.utc_now(:microsecond)

    with {:ok, _settings} <- ensure_operator_settings_for_local_operator(repo),
         {:ok, _settings} <- OperatorSettingsRepository.get(repo),
         {1, _rows} <-
           repo.update_all(append_hidden_work_package_id_query(work_package_id, now), []),
         %OperatorSettings{} = settings <- repo.get(OperatorSettings, OperatorSettings.settings_id()) do
      {:ok, settings}
    else
      {0, _rows} -> {:error, :not_found}
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_operator_settings_for_local_operator(module()) :: {:ok, OperatorSettings.t()} | {:error, term()}
  def ensure_operator_settings_for_local_operator(repo) do
    repo.insert(OperatorSettings.default(), on_conflict: :nothing, conflict_target: :id)
  end

  defp append_hidden_work_package_id_query(work_package_id, now) do
    from(settings in OperatorSettings,
      where: settings.id == ^OperatorSettings.settings_id(),
      update: [
        set: [
          hidden_work_package_ids:
            fragment(
              """
              CASE
                WHEN EXISTS (
                  SELECT 1
                  FROM json_each(COALESCE(?, '[]'))
                  WHERE value IS NOT NULL
                    AND value = ?
                )
                THEN COALESCE((
                  SELECT json_group_array(value)
                  FROM (
                    SELECT DISTINCT value
                    FROM json_each(COALESCE(?, '[]'))
                    WHERE value IS NOT NULL
                  )
                ), '[]')
                ELSE json_insert(
                  COALESCE((
                    SELECT json_group_array(value)
                    FROM (
                      SELECT DISTINCT value
                      FROM json_each(COALESCE(?, '[]'))
                      WHERE value IS NOT NULL
                    )
                  ), '[]'),
                  '$[#]',
                  ?
                )
              END
              """,
              settings.hidden_work_package_ids,
              ^work_package_id,
              settings.hidden_work_package_ids,
              settings.hidden_work_package_ids,
              ^work_package_id
            ),
          updated_at: ^now
        ]
      ]
    )
  end

  defp local_operator_transaction(repo, fun) when is_function(fun, 0) do
    repo.transaction(fn ->
      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> repo.rollback(reason)
      end
    end)
    |> normalize_local_operator_transaction_result()
  end

  defp normalize_local_operator_transaction_result({:ok, value}), do: {:ok, value}
  defp normalize_local_operator_transaction_result({:error, reason}), do: {:error, reason}

  defp refresh_work_requests_for_work_package(repo, work_package_id) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
      refresh_work_request_for_package(repo, work_package)
    end
  end

  defp refresh_work_request_for_package(repo, %WorkPackage{work_request_id: work_request_id})
       when is_binary(work_request_id),
       do: refresh_work_request_completion(repo, work_request_id)

  defp refresh_work_request_for_package(_repo, %WorkPackage{}), do: :ok

  defp refresh_work_request_completion(repo, work_request_id) do
    case WorkRequestService.refresh_completion(repo, work_request_id) do
      {:ok, _work_request} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec local_operator_comment_attrs(map()) :: map()
  def local_operator_comment_attrs(params) do
    %{
      "target_kind" => text_param(params, "target_kind"),
      "target_id" => text_param(params, "target_id"),
      "body" => text_param(params, "body"),
      "source_type" => "operator",
      "author_name" => @local_operator_actor
    }
  end

  @spec local_operator_comment_resolution_attrs(map()) :: map()
  def local_operator_comment_resolution_attrs(params) do
    %{
      "resolved_by" => @local_operator_actor,
      "resolved_source_type" => "operator",
      "resolution_note" => text_param(params, "resolution_note", "")
    }
  end

  @spec comment_payload(Comment.t()) :: map()
  def comment_payload(%Comment{} = comment) do
    %{
      id: comment.id,
      target_kind: comment.target_kind,
      target_id: comment.target_id,
      body: Redactor.redact_text(comment.body),
      source_type: comment.source_type,
      author_name: Redactor.redact_text(comment.author_name),
      status: comment.status,
      resolved_by: Redactor.redact_text(comment.resolved_by),
      resolved_source_type: comment.resolved_source_type,
      resolved_at: timestamp(comment.resolved_at),
      resolution_note: Redactor.redact_text(comment.resolution_note),
      inserted_at: timestamp(comment.inserted_at),
      updated_at: timestamp(comment.updated_at)
    }
  end

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp timestamp(nil), do: nil

  @spec scoped_question(module(), String.t(), String.t()) :: {:ok, ClarificationQuestion.t()} | {:error, term()}
  def scoped_question(repo, work_request_id, question_id) when is_binary(work_request_id) and is_binary(question_id) do
    with {:ok, questions} <- WorkRequestService.list_questions(repo, work_request_id) do
      case Enum.find(questions, &(&1.id == question_id)) do
        %ClarificationQuestion{} = question -> {:ok, question}
        nil -> {:error, :not_found}
      end
    end
  end

  def scoped_question(_repo, _work_request_id, _question_id), do: {:error, :not_found}

  @spec require_open_question(ClarificationQuestion.t()) :: :ok | {:error, atom()}
  def require_open_question(%ClarificationQuestion{status: "open"}), do: :ok
  def require_open_question(%ClarificationQuestion{status: "answered"}), do: {:error, :already_answered}
  def require_open_question(%ClarificationQuestion{status: "closed"}), do: {:error, :already_closed}
  def require_open_question(%ClarificationQuestion{}), do: {:error, :invalid_status}

  @spec local_operator_question_answer_attrs(ClarificationQuestion.t(), map()) :: {:ok, map()} | {:error, atom()}
  def local_operator_question_answer_attrs(%ClarificationQuestion{} = question, params) do
    case HumanDecisionPrompt.answer_text_result(question.decision_prompt, params) do
      {:ok, answer} ->
        case String.trim(answer) do
          "" -> {:error, :missing_answer}
          answer -> {:ok, %{"answer" => answer, "answered_by" => @local_operator_actor}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec text_param(map(), String.t(), term()) :: String.t() | term()
  def text_param(params, key, default \\ nil) do
    case Map.get(params, key) || Map.get(params, String.to_atom(key)) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: default, else: value

      nil ->
        default

      value ->
        to_string(value)
    end
  end

  @spec github_sync_opts(map()) :: keyword()
  def github_sync_opts(%{"mode" => "auto"}) do
    [
      client: Application.get_env(:symphony_elixir, :sympp_github_client, DefaultClient),
      require_authenticated_client?: true
    ]
  end

  def github_sync_opts(_params), do: []

  @spec architect_handoff_opts(module()) :: keyword()
  def architect_handoff_opts(repo) do
    [
      database: DashboardRuntime.dashboard_ledger_database(repo),
      claimed_by: ArchitectHandoff.claimed_by(),
      local_architect_claim?: true
    ]
  end

  @spec dispatch_handoff_opts(module()) :: keyword()
  def dispatch_handoff_opts(repo) do
    [
      database: DashboardRuntime.dashboard_ledger_database(repo),
      claimed_by: @local_operator_worker
    ]
  end
end
