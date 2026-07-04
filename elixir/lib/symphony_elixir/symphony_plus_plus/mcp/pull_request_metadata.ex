defmodule SymphonyElixir.SymphonyPlusPlus.MCP.PullRequestMetadata do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.GitHub.{Client, DryClient, PullRequest, PullRequestArtifact}
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session
  alias SymphonyElixir.SymphonyPlusPlus.Planning.ProgressEvent
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type repo :: module()
  @type tool_error :: {:tool_error, term()}

  @spec payload(repo(), Session.t(), map(), String.t()) :: {:ok, map()} | tool_error() | {:error, term()}
  def payload(repo, %Session{} = session, arguments, source_tool) do
    case legacy_attach_pr_payload(arguments, source_tool) do
      {:ok, payload} -> {:ok, payload}
      {:tool_error, reason} -> {:tool_error, reason}
      :error -> github_pr_metadata_payload(repo, session, arguments, source_tool)
    end
  end

  @spec validate_sync_target_unless_replay(repo(), Session.t(), map(), map(), String.t(), boolean()) ::
          :ok | tool_error() | {:error, term()}
  def validate_sync_target_unless_replay(_repo, %Session{}, _arguments, _payload, _tool, true), do: :ok
  def validate_sync_target_unless_replay(_repo, %Session{}, _arguments, _payload, "attach_pr", false), do: :ok

  def validate_sync_target_unless_replay(repo, %Session{} = session, arguments, payload, tool, false) do
    with {:ok, ref} <- PullRequest.parse(payload, nil),
         {:ok, repair?} <- pr_attachment_repair?(repo, session, arguments, tool) do
      validate_pr_sync_target(repo, session, ref, tool, repair?)
    end
  end

  @spec maybe_upsert_artifact(repo(), Session.t(), map(), boolean()) :: :ok | {:error, term()}
  def maybe_upsert_artifact(_repo, %Session{}, _payload, true), do: :ok

  def maybe_upsert_artifact(repo, %Session{} = session, payload, false) do
    PullRequestArtifact.upsert(repo, session.assignment.work_package_id, payload)
  end

  defp github_pr_metadata_payload(repo, %Session{} = session, arguments, source_tool) do
    with {:ok, %WorkPackage{} = work_package} <- WorkPackageRepository.get(repo, Session.work_package_id(session)),
         {:ok, metadata_input} <- pr_metadata_input(repo, session, arguments, source_tool),
         {:ok, arguments} <- pr_reference_arguments(repo, session, arguments, source_tool),
         {:ok, ref} <- PullRequest.parse(arguments, work_package.repo),
         {:ok, metadata} <- Client.fetch_pull_request(DryClient, ref, metadata: metadata_input),
         {:ok, payload} <- PullRequest.metadata(metadata, ref, pr_fallback_head_sha(arguments, source_tool)),
         {:ok, attachment_repair?} <- pr_attachment_repair?(repo, session, arguments, source_tool) do
      {:ok,
       payload
       |> Map.put("source_tool", source_tool)
       |> maybe_mark_pr_attachment_repair(attachment_repair?)}
    else
      {:tool_error, reason} ->
        {:tool_error, reason}

      {:error, reason} when reason in [:database_busy] ->
        {:error, reason}

      {:error, {reason, _detail} = error} when reason in [:storage_failed, :migration_failed, :service_unavailable] ->
        {:error, error}

      {:error, :missing_repository} ->
        {:tool_error, pr_missing_repository_reason(arguments, source_tool)}

      {:error, reason} ->
        {:tool_error, reason_text(reason)}
    end
  end

  defp legacy_attach_pr_payload(arguments, "attach_pr") do
    with url when is_binary(url) <- Map.get(arguments, "url"),
         trimmed_url = String.trim(url),
         true <- trimmed_url != "",
         true <- non_github_url?(trimmed_url),
         {:ok, metadata} <- legacy_pr_metadata(arguments) do
      payload =
        metadata
        |> Map.merge(%{"type" => "pr", "source_tool" => "attach_pr", "url" => trimmed_url})
        |> maybe_put_filled_string("head_sha", Map.get(arguments, "head_sha"))

      {:ok, payload}
    else
      {:tool_error, _reason} = error -> error
      _value -> :error
    end
  end

  defp legacy_attach_pr_payload(_arguments, _source_tool), do: :error

  defp legacy_pr_metadata(%{"metadata" => metadata}) when is_map(metadata), do: {:ok, metadata}
  defp legacy_pr_metadata(%{"metadata" => nil}), do: {:ok, %{}}
  defp legacy_pr_metadata(%{"metadata" => _metadata}), do: {:tool_error, "invalid_metadata"}
  defp legacy_pr_metadata(_arguments), do: {:ok, %{}}

  defp non_github_url?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) ->
        String.downcase(host) != "github.com"

      _uri ->
        false
    end
  rescue
    _error in URI.Error -> false
  end

  defp maybe_put_filled_string(payload, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> payload
      trimmed -> Map.put(payload, key, trimmed)
    end
  end

  defp maybe_put_filled_string(payload, _key, _value), do: payload

  defp pr_fallback_head_sha(arguments, tool) when tool in ["attach_pr", "sync_pr"], do: Map.get(arguments, "head_sha")

  defp pr_reference_arguments(repo, %Session{} = session, arguments, "sync_pr") do
    arguments = drop_blank_pr_identity_arguments(arguments)

    cond do
      sync_pr_recovery_arguments?(arguments) -> recovery_pr_reference_arguments(arguments)
      complete_pr_identity_argument?(arguments) -> {:ok, arguments}
      true -> infer_sync_pr_reference_arguments(repo, session, arguments)
    end
  end

  defp pr_reference_arguments(_repo, %Session{}, arguments, _source_tool), do: {:ok, arguments}

  defp infer_sync_pr_reference_arguments(repo, %Session{} = session, arguments) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, Session.work_package_id(session)) do
      sync_pr_reference_arguments_from_events(arguments, progress_events)
    end
  end

  defp sync_pr_reference_arguments_from_events(arguments, progress_events) do
    case latest_attached_pr_ref(progress_events) do
      {:ok, attached_ref} -> sync_pr_reference_arguments(arguments, attached_ref)
      {:tool_error, "missing_attached_pr"} -> fallback_pr_reference_arguments(arguments)
      {:tool_error, reason} -> {:tool_error, reason}
    end
  end

  defp sync_pr_reference_arguments(arguments, {:url, url}), do: {:ok, put_inferred_pr_argument(arguments, "url", url)}

  defp sync_pr_reference_arguments(arguments, {repository, number}) do
    {:ok,
     arguments
     |> put_inferred_pr_argument("repository", repository)
     |> put_inferred_pr_argument("number", number)}
  end

  defp explicit_pr_identity?(arguments) do
    filled_string?(Map.get(arguments, "url")) or not blank_pr_number_argument?(Map.get(arguments, "number"))
  end

  defp complete_pr_identity_argument?(arguments) do
    filled_string?(Map.get(arguments, "url")) or
      (not blank_pr_number_argument?(Map.get(arguments, "number")) and filled_string?(Map.get(arguments, "repository")))
  end

  defp fallback_pr_reference_arguments(arguments) do
    cond do
      sync_pr_recovery_arguments?(arguments) -> recovery_pr_reference_arguments(arguments)
      explicit_pr_identity?(arguments) -> {:ok, arguments}
      true -> {:tool_error, "missing_attached_pr"}
    end
  end

  defp sync_pr_recovery_arguments?(%{"recovery" => recovery}) when is_map(recovery), do: recovery_pr_identity?(recovery)
  defp sync_pr_recovery_arguments?(_arguments), do: false

  defp sync_pr_attachment_repair_arguments?(arguments) do
    sync_pr_recovery_arguments?(arguments) or explicit_pr_identity?(drop_blank_pr_identity_arguments(arguments))
  end

  defp pr_attachment_repair?(repo, %Session{} = session, arguments, "sync_pr") when is_map(arguments) do
    if sync_pr_attachment_repair_arguments?(arguments) do
      explicit_sync_pr_missing_attached_pr?(repo, session)
    else
      {:ok, false}
    end
  end

  defp pr_attachment_repair?(_repo, %Session{}, _arguments, _source_tool), do: {:ok, false}

  defp explicit_sync_pr_missing_attached_pr?(repo, %Session{} = session) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, Session.work_package_id(session)) do
      case latest_real_attached_pr_ref(progress_events) do
        {:ok, _attached_ref} -> {:ok, false}
        {:tool_error, "missing_attached_pr"} -> {:ok, true}
        {:tool_error, reason} -> {:tool_error, reason}
      end
    end
  end

  defp maybe_mark_pr_attachment_repair(payload, true), do: Map.put(payload, "attachment_repair", true)
  defp maybe_mark_pr_attachment_repair(payload, false), do: payload

  defp recovery_pr_reference_arguments(%{"recovery" => recovery} = arguments) when is_map(recovery) do
    recovery_arguments =
      %{}
      |> put_inferred_pr_argument("url", Map.get(recovery, "html_url") || Map.get(recovery, "url"))
      |> put_inferred_pr_argument("repository", recovery_repository(recovery))
      |> put_inferred_pr_argument("number", Map.get(recovery, "number"))

    if explicit_pr_identity?(recovery_arguments) do
      merge_recovery_pr_reference_arguments(arguments, recovery_arguments)
    else
      {:tool_error, "missing_attached_pr"}
    end
  end

  defp merge_recovery_pr_reference_arguments(arguments, recovery_arguments) do
    with :ok <- validate_recovery_number_argument(arguments, recovery_arguments) do
      case {pr_payload_ref(arguments), pr_payload_ref(recovery_arguments)} do
        {nil, _recovery_ref} -> {:ok, Map.merge(arguments, recovery_arguments)}
        {same_ref, same_ref} -> {:ok, Map.merge(arguments, recovery_arguments)}
        {_argument_ref, _recovery_ref} -> {:tool_error, "pr_recovery_reference_mismatch"}
      end
    end
  end

  defp validate_recovery_number_argument(arguments, recovery_arguments) do
    case {pr_number_argument(Map.get(arguments, "number")), pr_number_argument(Map.get(recovery_arguments, "number"))} do
      {nil, _recovery_number} -> :ok
      {_argument_number, nil} -> :ok
      {same_number, same_number} -> :ok
      {_argument_number, _recovery_number} -> {:tool_error, "pr_recovery_reference_mismatch"}
    end
  end

  defp recovery_pr_identity?(recovery) do
    filled_string?(Map.get(recovery, "url") || Map.get(recovery, "html_url")) or
      (not blank_pr_number_argument?(Map.get(recovery, "number")) and filled_string?(recovery_repository(recovery)))
  end

  defp pr_number_argument(value) when is_integer(value) and value > 0, do: value

  defp pr_number_argument(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {number, ""} when number > 0 -> number
      _value -> nil
    end
  end

  defp pr_number_argument(_value), do: nil

  defp recovery_repository(recovery) do
    case Map.get(recovery, "repository") do
      repository when is_binary(repository) -> repository
      %{"full_name" => full_name} when is_binary(full_name) -> full_name
      _repository -> nested_recovery_repository(recovery, "base") || nested_recovery_repository(recovery, "head")
    end
  end

  defp nested_recovery_repository(recovery, key) do
    case Map.get(recovery, key) do
      %{"repo" => %{"full_name" => full_name}} when is_binary(full_name) -> full_name
      _value -> nil
    end
  end

  defp drop_blank_pr_identity_arguments(arguments) do
    Enum.reduce(["url", "repository", "number"], arguments, &drop_blank_pr_identity_argument/2)
  end

  defp drop_blank_pr_identity_argument(key, arguments) do
    value = Map.get(arguments, key)

    if is_binary(value) and String.trim(value) == "", do: Map.delete(arguments, key), else: arguments
  end

  defp blank_pr_number_argument?(nil), do: true
  defp blank_pr_number_argument?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_pr_number_argument?(_value), do: false

  defp put_inferred_pr_argument(arguments, _key, nil), do: arguments

  defp put_inferred_pr_argument(arguments, key, value) when is_binary(value) do
    if String.trim(value) == "" do
      arguments
    else
      put_nonblank_inferred_pr_argument(arguments, key, value)
    end
  end

  defp put_inferred_pr_argument(arguments, key, value) do
    put_nonblank_inferred_pr_argument(arguments, key, value)
  end

  defp put_nonblank_inferred_pr_argument(arguments, key, value) do
    case Map.get(arguments, key) do
      existing when is_binary(existing) ->
        if String.trim(existing) == "", do: Map.put(arguments, key, value), else: arguments

      nil ->
        Map.put(arguments, key, value)

      _existing ->
        arguments
    end
  end

  defp pr_missing_repository_reason(arguments, "attach_pr") do
    if Map.has_key?(arguments, "number") and not filled_string?(Map.get(arguments, "url")) do
      "missing_repository_use_url_or_owner_repo"
    else
      "missing_repository"
    end
  end

  defp pr_missing_repository_reason(_arguments, _source_tool), do: "missing_repository"

  defp validate_pr_sync_target(_repo, %Session{}, _ref, "attach_pr", _repair?), do: :ok

  defp validate_pr_sync_target(repo, %Session{} = session, ref, "sync_pr", repair?) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, Session.work_package_id(session)) do
      validate_pr_sync_ref_against_events(ref, progress_events, repair?)
    end
  end

  defp validate_pr_sync_ref_against_events(ref, progress_events, repair?) do
    case latest_attached_pr_ref(progress_events) do
      {:ok, attached_ref} -> validate_pr_sync_ref(ref, attached_ref, repair?)
      {:tool_error, "missing_attached_pr"} -> :ok
      {:tool_error, reason} -> {:tool_error, reason}
    end
  end

  defp validate_pr_sync_ref(ref, attached_ref, _repair?) do
    if attached_ref == normalized_pr_ref(ref.repository, ref.number), do: :ok, else: {:tool_error, "pr_mismatch"}
  end

  defp latest_attached_pr_ref(progress_events) do
    case latest_attached_pr_ref_with_ledger_boundary(progress_events) do
      {:ok, ref, _boundary} -> {:ok, ref}
      {:tool_error, reason} -> {:tool_error, reason}
    end
  end

  defp latest_real_attached_pr_ref(progress_events) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find_value(&attached_pr_ref_with_boundary/1)
    |> case do
      nil -> {:tool_error, "missing_attached_pr"}
      {ref, _boundary} -> {:ok, ref}
    end
  end

  defp latest_attached_pr_ref_with_ledger_boundary(progress_events) do
    # Attach selection follows event time so replay/backfill can record older PR
    # attachments later. The returned boundary preserves that selected event.
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find_value(&attached_or_repaired_pr_ref_with_boundary/1)
    |> case do
      nil -> {:tool_error, "missing_attached_pr"}
      {ref, boundary} -> {:ok, ref, boundary}
    end
  end

  defp progress_event_sequence_order(%ProgressEvent{sequence: sequence, created_at: created_at, id: id}) when is_integer(sequence) do
    {1, sequence, timestamp_sort_value(created_at), id || ""}
  end

  defp progress_event_sequence_order(%ProgressEvent{created_at: created_at, id: id}) do
    {0, timestamp_sort_value(created_at), id || ""}
  end

  defp timestamp_sort_value(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :microsecond)
  defp timestamp_sort_value(nil), do: -1

  defp attach_boundary(%ProgressEvent{sequence: sequence} = event) when is_integer(sequence) do
    {:sequence, progress_event_sequence_order(event)}
  end

  defp attach_boundary(%ProgressEvent{} = event) do
    {:chronological, progress_event_chronological_order(event)}
  end

  defp chronological_progress_events(progress_events) do
    Enum.sort_by(progress_events, &progress_event_chronological_order/1)
  end

  defp progress_event_chronological_order(%ProgressEvent{created_at: created_at, sequence: sequence, id: id}) do
    {timestamp_sort_value(created_at), sequence || 0, id || ""}
  end

  defp attached_or_repaired_pr_ref_with_boundary(%ProgressEvent{} = event) do
    attached_pr_ref_with_boundary(event) || repaired_pr_ref_with_boundary(event)
  end

  defp attached_pr_ref_with_boundary(%ProgressEvent{payload: payload} = event) when is_map(payload) do
    if payload_type?(event, "pr", "attach_pr"), do: pr_payload_ref_with_sequence(payload, attach_boundary(event))
  end

  defp attached_pr_ref_with_boundary(_event), do: nil

  defp repaired_pr_ref_with_boundary(%ProgressEvent{payload: payload} = event) when is_map(payload) do
    if payload_type?(event, "pr", "sync_pr") and Map.get(payload, "attachment_repair") == true do
      pr_payload_ref_with_sequence(payload, {:repair_sync, attach_boundary(event)})
    end
  end

  defp repaired_pr_ref_with_boundary(_event), do: nil

  defp pr_payload_ref_with_sequence(payload, sequence) do
    case pr_payload_ref(payload) do
      nil -> nil
      ref -> {ref, sequence}
    end
  end

  defp pr_payload_ref(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_integer(number),
    do: normalized_pr_ref(repository, number)

  defp pr_payload_ref(%{"repository" => repository, "number" => number}) when is_binary(repository) and is_binary(number),
    do: normalized_pr_ref(repository, number)

  defp pr_payload_ref(%{"url" => url}) when is_binary(url) do
    case PullRequest.parse(%{"url" => url}, nil) do
      {:ok, ref} -> normalized_pr_ref(ref.repository, ref.number)
      {:error, _reason} -> legacy_url_ref(url)
    end
  end

  defp pr_payload_ref(_payload), do: nil

  defp normalized_pr_ref(repository, number) when is_binary(repository) do
    {String.downcase(repository), pr_number_argument(number) || number}
  end

  defp legacy_url_ref(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        if String.downcase(host) == "github.com", do: nil, else: {:url, url}

      _uri ->
        {:url, url}
    end
  rescue
    _error in URI.Error -> {:url, url}
  end

  defp pr_metadata_input(_repo, %Session{}, arguments, "attach_pr") do
    case Map.get(arguments, "metadata") do
      metadata when is_map(metadata) -> {:ok, metadata}
      nil -> {:ok, %{"head_sha" => Map.get(arguments, "head_sha")}}
      _metadata -> {:tool_error, "invalid_metadata"}
    end
  end

  defp pr_metadata_input(repo, %Session{} = session, arguments, "sync_pr") do
    cond do
      is_map(Map.get(arguments, "metadata")) ->
        {:ok, merge_compact_pr_metadata_fields(Map.get(arguments, "metadata"), arguments)}

      Map.has_key?(arguments, "metadata") ->
        {:tool_error, "invalid_metadata"}

      is_map(Map.get(arguments, "recovery")) ->
        {:ok, merge_compact_pr_metadata_fields(Map.get(arguments, "recovery"), arguments)}

      Map.has_key?(arguments, "recovery") ->
        {:tool_error, "invalid_recovery"}

      true ->
        compact_pr_metadata_input(repo, session, arguments)
    end
  end

  defp compact_pr_metadata_input(repo, %Session{} = session, arguments) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, Session.work_package_id(session)),
         {:ok, latest_payload} <- latest_current_attached_pr_payload(progress_events) do
      metadata =
        latest_payload
        |> discard_stale_pr_snapshot_metadata(arguments)
        |> discard_unavailable_changed_file_metadata()
        |> merge_compact_pr_metadata_fields(arguments)

      {:ok, metadata}
    else
      {:tool_error, "missing_attached_pr"} ->
        if explicit_pr_identity?(drop_blank_pr_identity_arguments(arguments)) do
          {:ok, Map.take(arguments, compact_pr_metadata_keys())}
        else
          {:tool_error, "missing_attached_pr"}
        end

      error ->
        error
    end
  end

  defp merge_compact_pr_metadata_fields(metadata, arguments) do
    Map.merge(metadata, compact_pr_metadata_fields(arguments))
  end

  defp discard_stale_pr_snapshot_metadata(metadata, arguments) do
    if compact_pr_head_changed?(metadata, arguments) do
      Map.drop(metadata, compact_pr_snapshot_metadata_keys())
    else
      metadata
    end
  end

  defp compact_pr_head_changed?(metadata, arguments) do
    case {compact_pr_head_sha(Map.get(arguments, "head_sha")), compact_pr_head_sha(Map.get(metadata, "head_sha"))} do
      {requested_head_sha, cached_head_sha} when is_binary(requested_head_sha) ->
        not PullRequest.head_sha_matches?(requested_head_sha, cached_head_sha)

      _heads ->
        false
    end
  end

  defp compact_pr_head_sha(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      head_sha -> head_sha
    end
  end

  defp compact_pr_head_sha(_value), do: nil

  defp discard_unavailable_changed_file_metadata(metadata) do
    metadata
    |> maybe_drop_unavailable_changed_files()
    |> maybe_drop_unavailable_changed_files_count()
  end

  defp maybe_drop_unavailable_changed_files(%{"changed_files_available" => true} = metadata), do: metadata
  defp maybe_drop_unavailable_changed_files(metadata), do: Map.delete(metadata, "changed_files")

  defp maybe_drop_unavailable_changed_files_count(%{"changed_files_count_available" => true} = metadata), do: metadata
  defp maybe_drop_unavailable_changed_files_count(metadata), do: Map.delete(metadata, "changed_files_count")

  defp compact_pr_metadata_keys do
    ["head_sha", "branch", "base_branch", "base_sha", "changed_files", "changed_files_count", "check_summary", "review_state", "merge_state"]
  end

  defp compact_pr_metadata_fields(arguments) do
    arguments
    |> Map.take(compact_pr_metadata_keys())
    |> Enum.reject(fn {_key, value} -> blank_argument?(value) end)
    |> Map.new()
  end

  defp compact_pr_snapshot_metadata_keys do
    [
      "base_sha",
      "base_branch",
      "changed_files",
      "changed_files_count",
      "changed_files_available",
      "changed_files_count_available",
      "check_summary",
      "review_state",
      "merge_state",
      "merged_at",
      "merge_commit_sha"
    ]
  end

  defp latest_current_attached_pr_payload(progress_events) do
    with {:ok, attached_ref, attach_boundary} <- latest_attached_pr_ref_with_ledger_boundary(progress_events) do
      latest_current_attached_pr_payload(progress_events, attached_ref, attach_boundary)
    end
  end

  defp latest_current_attached_pr_payload(progress_events, attached_ref, attach_boundary) do
    progress_events
    |> chronological_progress_events()
    |> Enum.reverse()
    |> Enum.find_value(&current_attached_pr_payload(&1, attached_ref, attach_boundary))
    |> case do
      nil -> {:tool_error, "missing_attached_pr"}
      payload -> {:ok, payload}
    end
  end

  defp current_attached_pr_payload(%ProgressEvent{payload: payload} = event, attached_ref, attach_boundary) when is_map(payload) do
    if current_pr_state_event?(event, attach_boundary) and pr_payload_ref(payload) == attached_ref, do: payload
  end

  defp current_attached_pr_payload(%ProgressEvent{}, _attached_ref, _attach_boundary), do: nil

  defp current_pr_state_event?(%ProgressEvent{} = event, {:repair_sync, repair_boundary}) do
    payload_type?(event, "pr", "sync_pr") and
      (attach_boundary(event) == repair_boundary or progress_after_pr_attach_boundary?(event, repair_boundary))
  end

  defp current_pr_state_event?(%ProgressEvent{} = event, attach_boundary) do
    (payload_type?(event, "pr", "attach_pr") and attach_boundary(event) == attach_boundary) or
      (payload_type?(event, "pr", "sync_pr") and progress_after_pr_attach_boundary?(event, attach_boundary))
  end

  defp progress_after_pr_attach_boundary?(%ProgressEvent{} = event, {:sequence, attach_boundary}) do
    progress_event_sequence_order(event) > attach_boundary
  end

  defp progress_after_pr_attach_boundary?(%ProgressEvent{} = event, {:chronological, attach_boundary}) do
    progress_event_chronological_order(event) > attach_boundary
  end

  defp progress_after_pr_attach_boundary?(%ProgressEvent{}, _attach_boundary), do: false

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""

  defp payload_type?(%ProgressEvent{payload: payload}, type, source_tool) when is_map(payload) do
    Map.get(payload, "type") == type and Map.get(payload, "source_tool") == source_tool
  end

  defp payload_type?(%ProgressEvent{}, _type, _source_tool), do: false

  defp blank_argument?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank_argument?(nil), do: true
  defp blank_argument?(_value), do: false

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
