defmodule SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Id
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Normalization
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Repository
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry

  @type error :: Repository.error()
  @entry_attr_keys [
    {"blocker_id", :blocker_id},
    {"body", :body},
    {"command", :command},
    {"decision", :decision},
    {"evidence", :evidence},
    {"idempotency_key", :idempotency_key},
    {"payload", :payload},
    {"rationale", :rationale},
    {"resolution", :resolution},
    {"result", :result},
    {"scope_impact", :scope_impact},
    {"severity", :severity},
    {"status", :status},
    {"summary", :summary}
  ]

  @spec create_or_attach_current(Repository.repo(), map()) :: {:ok, SoloSession.t()} | {:error, error()}
  def create_or_attach_current(repo, attrs), do: Repository.create_or_attach_current(repo, attrs)

  @spec get(Repository.repo(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def get(repo, id), do: Repository.get(repo, id)

  @spec list(Repository.repo()) :: {:ok, [SoloSession.t()]} | {:error, error()}
  @spec list(Repository.repo(), map()) :: {:ok, [SoloSession.t()]} | {:error, error()}
  def list(repo, filters \\ %{}), do: Repository.list(repo, filters)

  @spec update_status(Repository.repo(), String.t(), String.t(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def update_status(repo, id, current_status, next_status), do: Repository.update_status(repo, id, current_status, next_status)

  @spec apply_lifecycle_action(Repository.repo(), String.t(), String.t()) :: {:ok, SoloSession.t()} | {:error, error() | term()}
  def apply_lifecycle_action(repo, solo_session_id, action) do
    with {:ok, action} <- Normalization.normalize_lifecycle_action(action),
         {:ok, %SoloSession{} = session} <- get(repo, solo_session_id) do
      next_status = Normalization.lifecycle_status_for_action(action)

      if session.status == next_status do
        {:ok, session}
      else
        update_status(repo, solo_session_id, session.status, next_status)
      end
    end
  end

  @spec pause(Repository.repo(), String.t(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def pause(repo, solo_session_id, current_status), do: Repository.update_status(repo, solo_session_id, current_status, "paused")

  @spec resume(Repository.repo(), String.t(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def resume(repo, solo_session_id, current_status), do: Repository.update_status(repo, solo_session_id, current_status, "active")

  @spec complete(Repository.repo(), String.t(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def complete(repo, solo_session_id, current_status), do: Repository.update_status(repo, solo_session_id, current_status, "completed")

  @spec archive(Repository.repo(), String.t(), String.t()) :: {:ok, SoloSession.t()} | {:error, error()}
  def archive(repo, solo_session_id, current_status), do: Repository.update_status(repo, solo_session_id, current_status, "archived")

  @spec archive_stale(Repository.repo()) :: {:ok, non_neg_integer()} | {:error, error()}
  def archive_stale(repo), do: Repository.archive_stale(repo)

  @spec archive_stale(Repository.repo(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, error()}
  def archive_stale(repo, now), do: Repository.archive_stale(repo, now)

  @spec delete_archived(Repository.repo()) :: {:ok, non_neg_integer()} | {:error, error()}
  def delete_archived(repo), do: Repository.delete_archived(repo)

  @spec delete_archived(Repository.repo(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, error()}
  def delete_archived(repo, now), do: Repository.delete_archived(repo, now)

  @spec retention_pass(Repository.repo(), DateTime.t()) ::
          {:ok, %{archived: non_neg_integer(), deleted: non_neg_integer()}} | {:error, error()}
  def retention_pass(repo, now) do
    with {:ok, archived} <- archive_stale(repo, now),
         {:ok, deleted} <- delete_archived(repo, now) do
      {:ok, %{archived: archived, deleted: deleted}}
    end
  end

  @spec append_entry(Repository.repo(), String.t(), map()) :: {:ok, SoloSessionEntry.t()} | {:error, error()}
  def append_entry(repo, solo_session_id, attrs), do: Repository.append_entry(repo, solo_session_id, attrs)

  @spec append_progress(Repository.repo(), String.t(), map()) :: {:ok, SoloSessionEntry.t()} | {:error, error() | term()}
  def append_progress(repo, solo_session_id, attrs), do: append_summary_entry(repo, solo_session_id, "progress", attrs)

  @spec record_task_plan(Repository.repo(), String.t(), map()) :: {:ok, SoloSessionEntry.t()} | {:error, error() | term()}
  def record_task_plan(repo, solo_session_id, attrs), do: append_summary_entry(repo, solo_session_id, "task_plan", attrs)

  @spec append_finding(Repository.repo(), String.t(), map()) :: {:ok, SoloSessionEntry.t()} | {:error, error() | term()}
  def append_finding(repo, solo_session_id, attrs) do
    append_summary_entry(repo, solo_session_id, "finding", attrs, fn payload, attrs ->
      put_present(payload, "severity", text(attrs, "severity"))
    end)
  end

  @spec record_decision(Repository.repo(), String.t(), map()) :: {:ok, SoloSessionEntry.t()} | {:error, error() | term()}
  def record_decision(repo, solo_session_id, attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, decision} <- required_text(attrs, "decision"),
         {:ok, payload} <- payload(attrs) do
      rationale = text(attrs, "rationale")
      scope_impact = text(attrs, "scope_impact")

      payload =
        payload
        |> put_present("decision", decision)
        |> put_present("rationale", rationale)
        |> put_present("scope_impact", scope_impact)

      attrs = put_body(attrs, decision_body(attrs, rationale, scope_impact))
      append_entry(repo, solo_session_id, entry_attrs("decision", decision, attrs, "recorded", payload))
    end
  end

  @spec report_blocker(Repository.repo(), String.t(), map()) :: {:ok, SoloSessionEntry.t()} | {:error, error() | term()}
  def report_blocker(repo, solo_session_id, attrs) do
    attrs = normalize_attrs(attrs)

    with :ok <- reject_field(attrs, "status"),
         {:ok, summary} <- required_text(attrs, "summary"),
         {:ok, payload} <- payload(attrs) do
      blocker_id = text(attrs, "blocker_id") || stable_blocker_id()

      payload =
        payload
        |> Map.put("blocker_id", blocker_id)
        |> Map.put("blocker_status", "open")

      append_entry(repo, solo_session_id, entry_attrs("blocker", summary, attrs, "blocked", payload))
    end
  end

  @spec resolve_blocker(Repository.repo(), String.t(), map()) :: {:ok, SoloSessionEntry.t()} | {:error, error() | term()}
  def resolve_blocker(repo, solo_session_id, attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, blocker_id} <- required_text(attrs, "blocker_id"),
         {:ok, resolution} <- required_text(attrs, "resolution"),
         {:ok, payload} <- payload(attrs) do
      title = text(attrs, "summary") || "Resolved blocker #{blocker_id}"

      payload =
        payload
        |> Map.put("blocker_id", blocker_id)
        |> Map.put("blocker_status", "resolved")
        |> Map.put("resolution", resolution)

      attrs = put_body(attrs, text(attrs, "body") || resolution)
      entry_attrs = entry_attrs("blocker", title, attrs, "resolved", payload)
      append_blocker_resolution(repo, solo_session_id, blocker_id, entry_attrs)
    end
  end

  @spec record_validation(Repository.repo(), String.t(), map()) :: {:ok, SoloSessionEntry.t()} | {:error, error() | term()}
  def record_validation(repo, solo_session_id, attrs) do
    attrs = normalize_attrs(attrs)

    with {:ok, summary} <- required_text(attrs, "summary"),
         {:ok, result} <- attrs |> text("result") |> Normalization.normalize_validation_result(),
         {:ok, payload} <- payload(attrs) do
      command = text(attrs, "command")
      evidence = text(attrs, "evidence")

      payload =
        payload
        |> Map.put("result", result)
        |> put_present("command", command)
        |> put_present("evidence", evidence)

      attrs = put_body(attrs, text(attrs, "body") || evidence)
      status = Normalization.validation_entry_status(result)
      append_entry(repo, solo_session_id, entry_attrs("validation_note", summary, attrs, status, payload))
    end
  end

  @spec get_entry(Repository.repo(), String.t(), String.t()) :: {:ok, SoloSessionEntry.t()} | {:error, error()}
  def get_entry(repo, solo_session_id, entry_id), do: Repository.get_entry(repo, solo_session_id, entry_id)

  @spec list_entries(Repository.repo(), String.t()) :: {:ok, [SoloSessionEntry.t()]} | {:error, error()}
  def list_entries(repo, solo_session_id), do: Repository.list_entries(repo, solo_session_id)

  defp append_summary_entry(repo, solo_session_id, kind, attrs, decorate_payload_fun \\ fn payload, _attrs -> payload end) do
    attrs = normalize_attrs(attrs)

    with {:ok, title} <- required_text(attrs, "summary"),
         {:ok, status} <- friendly_status(attrs, "recorded"),
         {:ok, payload} <- payload(attrs) do
      entry_attrs = entry_attrs(kind, title, attrs, status, decorate_payload_fun.(payload, attrs))
      append_entry(repo, solo_session_id, entry_attrs)
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(@entry_attr_keys, fn {string_key, atom_key} ->
      {string_key, Map.get(attrs, string_key) || Map.get(attrs, atom_key)}
    end)
  end

  defp normalize_attrs(_attrs), do: %{}

  defp friendly_status(attrs, default) do
    attrs
    |> text("status")
    |> Normalization.normalize_friendly_entry_status(default)
  end

  defp entry_attrs(kind, title, attrs, status, payload) do
    %{
      "entry_kind" => kind,
      "title" => title,
      "body" => text(attrs, "body"),
      "status" => status,
      "idempotency_key" => text(attrs, "idempotency_key"),
      "payload" => payload
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp decision_body(attrs, rationale, scope_impact) do
    text(attrs, "body") ||
      [
        labeled_line("Rationale", rationale),
        labeled_line("Scope impact", scope_impact)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")
      |> case do
        "" -> nil
        body -> body
      end
  end

  defp labeled_line(_label, nil), do: nil
  defp labeled_line(label, value), do: "#{label}: #{value}"

  defp payload(attrs) do
    case Map.get(attrs, "payload") do
      nil -> {:ok, %{}}
      payload when is_map(payload) -> {:ok, payload}
      _value -> {:error, {:invalid_solo_payload, "payload"}}
    end
  end

  defp required_text(attrs, key) do
    case text(attrs, key) do
      nil -> {:error, {:missing_required_solo_field, key}}
      value -> {:ok, value}
    end
  end

  defp reject_field(attrs, key) do
    case text(attrs, key) do
      nil -> :ok
      _value -> {:error, {:unsupported_solo_field, key}}
    end
  end

  defp append_blocker_resolution(repo, solo_session_id, blocker_id, entry_attrs) do
    case replay_matching_blocker_resolution(repo, solo_session_id, entry_attrs) do
      {:ok, %SoloSessionEntry{}} = ok -> ok
      :not_found -> append_open_blocker_resolution(repo, solo_session_id, blocker_id, entry_attrs)
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_open_blocker_resolution(repo, solo_session_id, blocker_id, entry_attrs) do
    with :ok <- require_open_blocker(repo, solo_session_id, blocker_id) do
      append_entry(repo, solo_session_id, entry_attrs)
    end
  end

  defp replay_matching_blocker_resolution(repo, solo_session_id, %{"idempotency_key" => idempotency_key} = attrs)
       when is_binary(idempotency_key) do
    with {:ok, entries} <- list_entries(repo, solo_session_id),
         %SoloSessionEntry{} = entry <- Enum.find(entries, &(&1.idempotency_key == idempotency_key)) do
      replay_blocker_resolution_entry(entry, attrs)
    else
      nil -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp replay_matching_blocker_resolution(_repo, _solo_session_id, _attrs), do: :not_found

  defp replay_blocker_resolution_entry(entry, attrs) do
    if matching_blocker_resolution?(entry, attrs), do: {:ok, entry}, else: {:error, :idempotency_key_conflict}
  end

  defp matching_blocker_resolution?(%SoloSessionEntry{entry_kind: "blocker"} = entry, %{"payload" => payload}) do
    Normalization.blocker_status(entry) == "resolved" and
      Normalization.blocker_identity(entry) == Map.get(payload, "blocker_id") and
      Normalization.blocker_resolution(entry) == Map.get(payload, "resolution")
  end

  defp matching_blocker_resolution?(_entry, _attrs), do: false

  defp text(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      _value ->
        nil
    end
  end

  defp put_body(attrs, nil), do: attrs
  defp put_body(attrs, body), do: Map.put(attrs, "body", body)

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp require_open_blocker(repo, solo_session_id, blocker_id) do
    with {:ok, entries} <- list_entries(repo, solo_session_id) do
      if Map.get(Normalization.active_blocker_statuses(entries), blocker_id) == "open" do
        :ok
      else
        {:error, :solo_blocker_not_open}
      end
    end
  end

  defp stable_blocker_id do
    Id.random("solo_blocker")
  end
end
