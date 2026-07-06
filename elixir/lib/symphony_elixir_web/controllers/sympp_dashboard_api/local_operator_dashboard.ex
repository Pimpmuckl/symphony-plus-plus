defmodule SymphonyElixirWeb.SymppDashboardAPI.LocalOperatorDashboard do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Repository, as: OperatorSettingsRepository
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.RetentionThrottle
  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings, as: OperatorSettings
  alias SymphonyElixir.SymphonyPlusPlus.Repo
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service, as: SoloSessionService
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.PlannedSlice
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Service, as: WorkRequestService
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @local_operator_actor "local-operator"
  @local_operator_hideable_package_statuses ["merged", "merged_into_phase", "closed", "abandoned"]
  @architect_handoff_anchor_id_prefix "SYMPP-WR-ARCH-"
  @architect_handoff_anchor_id_like @architect_handoff_anchor_id_prefix <> "%"
  @architect_handoff_anchor_kind "delegation"

  @spec operator_dashboard_payload(module()) :: {:ok, map()} | {:error, term()}
  def operator_dashboard_payload(repo) do
    with {:ok, context} <- operator_dashboard_context(repo) do
      opts = dashboard_opts(context)

      with {:ok, board} <- Dashboard.operator_board(repo, opts),
           {:ok, work_requests} <- Dashboard.work_requests(repo, opts),
           {:ok, guidance_requests} <- Dashboard.human_guidance_requests(repo, opts) do
        dashboard_payload(context, board, work_requests, guidance_requests)
      end
    end
  end

  defp dashboard_payload(context, board, work_requests, guidance_requests) do
    {board, active_blocking_edges} = local_operator_board(board, context.hidden_work_package_ids)

    {:ok,
     context
     |> base_payload(board, active_blocking_edges)
     |> Map.merge(%{
       work_requests: work_requests,
       archived_work_requests: empty_work_requests(),
       work_request_details: [],
       guidance_requests: guidance_requests,
       solo_sessions: empty_solo_sessions(),
       deferred: %{dashboard_sections: true}
     })}
  end

  @spec operator_dashboard_deferred_payload(module()) :: {:ok, map()} | {:error, term()}
  def operator_dashboard_deferred_payload(repo) do
    with {:ok, context} <- operator_dashboard_context(repo) do
      opts = dashboard_opts(context)

      with {:ok, work_requests} <- Dashboard.work_requests(repo, opts),
           {:ok, archived_work_requests} <- Dashboard.archived_work_requests(repo, opts),
           {:ok, solo_sessions} <- Dashboard.solo_sessions(repo, %{}, opts),
           {:ok, work_request_details} <-
             operator_work_request_board_details(repo, Map.get(work_requests, :work_requests, []), context.repo_identity_catalog) do
        {:ok,
         %{
           generated_at: DateTime.utc_now(:microsecond) |> DateTime.to_iso8601(),
           archived_work_requests: archived_work_requests,
           work_request_details: work_request_details,
           solo_sessions: solo_sessions,
           deferred: %{dashboard_sections: false}
         }}
      end
    end
  end

  defp operator_dashboard_context(repo) do
    with {:ok, repo_identity_catalog} <- Dashboard.local_operator_repo_identity_catalog(repo),
         {:ok, settings} <- OperatorSettingsRepository.get(repo),
         :ok <- run_operator_retention(repo, settings),
         {:ok, settings} <- OperatorSettingsRepository.get(repo),
         {:ok, linked_work_package_id_sets} <- linked_work_package_id_sets(repo),
         {:ok, architect_handoff_anchor_work_package_ids} <- architect_handoff_anchor_work_package_ids(repo),
         {:ok, settings} <- dedupe_hidden_work_package_ids_for_local_operator(repo, settings),
         {:ok, expired_unlinked_work_package_ids} <-
           expired_unlinked_work_package_ids_for_local_operator(repo, settings, linked_work_package_id_sets.active) do
      hidden_work_package_ids =
        settings
        |> effective_hidden_work_package_ids(linked_work_package_id_sets.active)
        |> MapSet.union(expired_unlinked_work_package_ids)
        |> MapSet.union(linked_work_package_id_sets.archived_only)
        |> MapSet.union(architect_handoff_anchor_work_package_ids)

      {:ok,
       %{
         repo: repo,
         repo_identity_catalog: repo_identity_catalog,
         hidden_work_package_ids: hidden_work_package_ids,
         settings: operator_settings_payload(settings),
         linked_work_package_ids: linked_work_package_id_sets.persisted |> MapSet.to_list() |> Enum.sort()
       }}
    end
  end

  defp dashboard_opts(context) do
    [repo_identity_catalog: context.repo_identity_catalog, hidden_work_package_ids: context.hidden_work_package_ids]
  end

  defp local_operator_board(board, hidden_work_package_ids) do
    active_blocking_edges = Map.get(board, :active_blocking_edges, [])

    board =
      board
      |> Map.delete(:active_blocking_edges)
      |> hide_local_operator_work_packages(hidden_work_package_ids)

    {board, hide_local_operator_blocking_edges(active_blocking_edges, hidden_work_package_ids)}
  end

  defp base_payload(context, board, active_blocking_edges) do
    %{
      generated_at: DateTime.utc_now(:microsecond) |> DateTime.to_iso8601(),
      ledger: %{database: dashboard_ledger_database(context.repo)},
      active_blocking_edges: active_blocking_edges,
      board: board,
      settings: context.settings,
      linked_work_package_ids: context.linked_work_package_ids
    }
  end

  defp empty_work_requests, do: %{work_requests: [], total_count: 0}
  defp empty_solo_sessions, do: %{solo_sessions: [], total_count: 0}

  defp hide_local_operator_work_packages(board, hidden_ids) do
    groups = Map.get(board, :groups, %{})

    groups =
      Map.new(groups, fn {status, cards} ->
        {status, Enum.reject(cards, &MapSet.member?(hidden_ids, Map.get(&1, :id)))}
      end)

    board
    |> Map.put(:groups, groups)
    |> Map.put(:visible_count, groups |> Map.values() |> Enum.map(&length/1) |> Enum.sum())
  end

  defp hide_local_operator_blocking_edges(active_blocking_edges, hidden_ids) do
    Enum.reject(active_blocking_edges, &MapSet.member?(hidden_ids, Map.get(&1, :work_package_id)))
  end

  defp effective_hidden_work_package_ids(%OperatorSettings{} = settings, linked_work_package_ids) do
    settings.hidden_work_package_ids
    |> MapSet.new()
    |> MapSet.difference(linked_work_package_ids)
  end

  defp dedupe_hidden_work_package_ids_for_local_operator(repo, %OperatorSettings{} = settings) do
    hidden_work_package_ids = Enum.uniq(settings.hidden_work_package_ids)

    if hidden_work_package_ids == settings.hidden_work_package_ids do
      {:ok, settings}
    else
      OperatorSettingsRepository.update(repo, %{"hidden_work_package_ids" => hidden_work_package_ids})
    end
  end

  defp expired_unlinked_work_package_ids_for_local_operator(repo, %OperatorSettings{} = settings, linked_work_package_ids) do
    cutoff = DateTime.add(DateTime.utc_now(:microsecond), -settings.work_request_archive_after_days * 24 * 60 * 60, :second)

    WorkPackage
    |> expired_terminal_work_package_query(cutoff)
    |> repo.all()
    |> MapSet.new(& &1.id)
    |> MapSet.difference(linked_work_package_ids)
    |> then(&{:ok, &1})
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp expired_terminal_work_package_query(queryable, cutoff) do
    from(work_package in queryable,
      left_join: planned_slice in PlannedSlice,
      on: planned_slice.work_package_id == work_package.id,
      left_join: child_work_package in WorkPackage,
      on: child_work_package.parent_id == work_package.id,
      where: work_package.status in ^@local_operator_hideable_package_statuses,
      where: is_nil(work_package.parent_id),
      where: is_nil(work_package.phase_id),
      where: is_nil(planned_slice.id),
      where: is_nil(child_work_package.id),
      where: work_package.updated_at <= ^cutoff,
      order_by: [asc: work_package.updated_at, asc: work_package.id]
    )
  end

  defp linked_work_package_id_sets(repo) do
    rows =
      repo.all(
        from(planned_slice in PlannedSlice,
          left_join: work_request in WorkRequest,
          on: work_request.id == planned_slice.work_request_id,
          where: not is_nil(planned_slice.work_package_id),
          select: {planned_slice.work_package_id, work_request.id, work_request.archived_at}
        )
      )

    sets =
      Enum.reduce(rows, %{persisted: MapSet.new(), active: MapSet.new(), archived: MapSet.new()}, fn
        {work_package_id, nil, _archived_at}, sets ->
          %{sets | persisted: MapSet.put(sets.persisted, work_package_id)}

        {work_package_id, _work_request_id, nil}, sets ->
          %{
            sets
            | persisted: MapSet.put(sets.persisted, work_package_id),
              active: MapSet.put(sets.active, work_package_id)
          }

        {work_package_id, _work_request_id, _archived_at}, sets ->
          %{
            sets
            | persisted: MapSet.put(sets.persisted, work_package_id),
              archived: MapSet.put(sets.archived, work_package_id)
          }
      end)

    {:ok,
     %{
       persisted: sets.persisted,
       active: sets.active,
       archived_only: MapSet.difference(sets.archived, sets.active)
     }}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp architect_handoff_anchor_work_package_ids(repo) do
    ids =
      repo.all(
        from(work_package in WorkPackage,
          where: work_package.kind == @architect_handoff_anchor_kind,
          where: like(work_package.id, ^@architect_handoff_anchor_id_like),
          select: work_package.id
        )
      )

    {:ok, MapSet.new(ids)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec operator_work_request_detail_payload(module(), String.t()) :: {:ok, map()} | {:error, term()}
  def operator_work_request_detail_payload(repo, work_request_id) when is_binary(work_request_id) do
    with {:ok, repo_identity_catalog} <- Dashboard.local_operator_repo_identity_catalog(repo) do
      Dashboard.work_request_detail(repo, work_request_id, repo_identity_catalog: repo_identity_catalog)
    end
  end

  @spec operator_work_request_board_details(module(), [map()], term()) :: {:ok, [map()]} | {:error, term()}
  def operator_work_request_board_details(repo, work_request_cards, repo_identity_catalog) when is_list(work_request_cards) do
    work_request_ids =
      work_request_cards
      |> Enum.map(&Map.get(&1, :id))
      |> Enum.reject(&is_nil/1)

    Dashboard.work_request_board_details(repo, work_request_ids, repo_identity_catalog: repo_identity_catalog)
  end

  @spec work_request_attrs(map()) :: map()
  def work_request_attrs(params) do
    %{
      "title" => text_param(params, "title"),
      "repo" => text_param(params, "repo"),
      "base_branch" => text_param(params, "base_branch"),
      "work_type" => text_param(params, "work_type", "feature"),
      "human_description" => text_param(params, "human_description"),
      "desired_dispatch_shape" => text_param(params, "desired_dispatch_shape", "architect_led_feature_branch"),
      "status" => text_param(params, "status", "ready_for_clarification"),
      "creator_kind" => text_param(params, "creator_kind", "human"),
      "creator_name" => text_param(params, "creator_name", @local_operator_actor),
      "created_via" => text_param(params, "created_via", "cockpit"),
      "constraints" => constraints_param(params)
    }
  end

  @spec operator_settings_attrs(map()) :: map()
  def operator_settings_attrs(params) do
    %{}
    |> put_settings_param(params, "work_request_archive_after_days")
    |> put_settings_param(params, "solo_session_delete_after_days")
  end

  defp put_settings_param(attrs, params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(attrs, key, value)
      :error -> put_atom_settings_param(attrs, params, key)
    end
  end

  defp put_atom_settings_param(attrs, params, key) do
    atom_key = String.to_existing_atom(key)

    case Map.fetch(params, atom_key) do
      {:ok, value} -> Map.put(attrs, key, value)
      :error -> attrs
    end
  end

  @spec operator_settings_payload(OperatorSettings.t()) :: map()
  def operator_settings_payload(%OperatorSettings{} = settings) do
    %{
      work_request_archive_after_days: settings.work_request_archive_after_days,
      solo_session_delete_after_days: settings.solo_session_delete_after_days,
      hidden_work_package_ids: settings.hidden_work_package_ids
    }
  end

  @spec run_operator_retention(module(), OperatorSettings.t(), keyword()) :: :ok | {:error, term()}
  def run_operator_retention(repo, %OperatorSettings{} = settings, opts \\ []) do
    RetentionThrottle.run(repo, settings, &run_operator_retention_pass(repo, settings, &1), opts)
  end

  defp run_operator_retention_pass(repo, %OperatorSettings{} = settings, now) do
    with {:ok, _work_request_summary} <-
           WorkRequestService.retention_pass(repo,
             archive_after_days: settings.work_request_archive_after_days,
             delete_after_days: settings.solo_session_delete_after_days
           ),
         {:ok, _solo_archived_count} <-
           SoloSessionService.archive_stale(repo, now, settings.work_request_archive_after_days),
         {:ok, _solo_deleted_count} <-
           SoloSessionService.delete_archived(repo, now, settings.solo_session_delete_after_days) do
      :ok
    end
  end

  @spec archived_work_request_payload(WorkRequest.t()) :: map()
  def archived_work_request_payload(work_request) do
    %{
      id: work_request.id,
      completed_at: timestamp(work_request.completed_at),
      archived_at: timestamp(work_request.archived_at),
      archive_reason: work_request.archive_reason
    }
  end

  @spec work_request_mutation_payload(WorkRequest.t()) :: map()
  def work_request_mutation_payload(%WorkRequest{} = work_request) do
    %{
      id: work_request.id,
      completed_at: timestamp(work_request.completed_at),
      completion_source: work_request.completion_source,
      archived_at: timestamp(work_request.archived_at),
      archive_reason: work_request.archive_reason,
      operational_state: completed_work_request_mutation_state(work_request)
    }
  end

  defp completed_work_request_mutation_state(%WorkRequest{completed_at: %DateTime{}, status: status}) do
    %{key: "completed", label: "Completed", tone: "success", raw_status: status}
  end

  defp completed_work_request_mutation_state(%WorkRequest{}), do: nil

  defp dashboard_ledger_database(repo) do
    Repo.operator_database_path(repo)
  end

  defp timestamp(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)
  defp timestamp(nil), do: nil

  defp constraints_param(%{"constraints" => constraints}) when is_map(constraints), do: constraints
  defp constraints_param(%{constraints: constraints}) when is_map(constraints), do: constraints

  defp constraints_param(params) do
    params
    |> Map.take(["allowed_paths", "forbidden_paths", "stop_conditions", "compatibility_stance", "validation_expectations", "dependencies_notes"])
    |> Enum.reject(fn {_key, value} -> blank_param?(value) end)
    |> Map.new(fn {key, value} -> {key, normalize_constraint_value(value)} end)
  end

  defp normalize_constraint_value(value) when is_list(value), do: value |> Enum.map(&text_value/1) |> Enum.reject(&(&1 == ""))
  defp normalize_constraint_value(value) when is_binary(value), do: newline_list(value)
  defp normalize_constraint_value(value), do: value

  defp newline_list(value) do
    value
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp text_param(params, key, default \\ nil) do
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

  defp text_value(value) when is_binary(value), do: String.trim(value)
  defp text_value(nil), do: ""
  defp text_value(value), do: to_string(value)

  defp blank_param?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_param?(value) when is_list(value), do: value |> Enum.map(&text_value/1) |> Enum.all?(&(&1 == ""))
  defp blank_param?(nil), do: true
  defp blank_param?(_value), do: false

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
end
