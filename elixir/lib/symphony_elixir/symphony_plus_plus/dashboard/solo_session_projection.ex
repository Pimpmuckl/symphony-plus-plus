defmodule SymphonyElixir.SymphonyPlusPlus.Dashboard.SoloSessionProjection do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.Sanitizer
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Normalization, as: SoloSessionNormalization
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.Service, as: SoloSessionsService
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSession
  alias SymphonyElixir.SymphonyPlusPlus.SoloSessions.SoloSessionEntry
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  import Ecto.Query, only: [from: 2]

  @query_chunk_size 500
  @snippet_limit 120

  @type repo :: module()
  @type dashboard_error :: :not_found | :forbidden | :database_busy | {:storage_failed, String.t()} | term()

  @spec list(repo(), map(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def list(repo, filters, opts) when is_atom(repo) and is_map(filters) and is_list(opts) do
    safe_read(fn ->
      with {:ok, sessions} <- SoloSessionsService.list(repo, filters),
           {:ok, repo_identity_catalog} <- repo_identity_catalog_from_repo(repo, opts, Enum.map(sessions, & &1.repo)),
           {:ok, cards} <- cards(repo, sessions, repo_identity_catalog) do
        {:ok,
         %{
           solo_sessions: cards,
           total_count: length(cards)
         }}
      end
    end)
  end

  @spec detail(repo(), String.t(), keyword()) :: {:ok, map()} | {:error, dashboard_error()}
  def detail(repo, solo_session_id, opts) when is_atom(repo) and is_binary(solo_session_id) and is_list(opts) do
    safe_read(fn ->
      with {:ok, session} <- SoloSessionsService.get(repo, solo_session_id),
           {:ok, entries} <- SoloSessionsService.list_entries(repo, solo_session_id) do
        repo_identity_catalog = repo_identity_catalog_from_opts(opts, [session.repo])

        {:ok,
         %{
           solo_session: session_payload(session, repo_identity_catalog),
           entries: Enum.map(entries, &detail_entry/1),
           entry_count: length(entries)
         }}
      end
    end)
  end

  @spec repos(repo()) :: {:ok, [String.t()]} | {:error, dashboard_error()}
  def repos(repo) when is_atom(repo) do
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

  @spec streams(repo(), keyword()) :: {:ok, [map()]} | {:error, dashboard_error()}
  def streams(repo, opts) when is_atom(repo) and is_list(opts) do
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
        {:ok, canonical_streams(raw_streams, repo_identity_catalog)}
      end
    end)
  end

  @spec count(repo()) :: {:ok, non_neg_integer()} | {:error, dashboard_error()}
  def count(repo) when is_atom(repo) do
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

  defp canonical_streams(streams, repo_identity_catalog) do
    streams
    |> Enum.map(&Map.merge(&1, RepoIdentity.fields(repo_identity_catalog, &1.repo)))
    |> Enum.group_by(&{&1.repo_key || &1.repo, &1.base_branch})
    |> Enum.map(fn {_key, grouped_streams} -> canonical_stream(grouped_streams) end)
    |> Enum.sort_by(&{&1.repo_key || &1.repo || "", &1.base_branch || ""})
  end

  defp canonical_stream([first | _rest] = streams) do
    %{
      repo: preferred_stream_repo(streams),
      repo_key: first.repo_key,
      repo_display: first.repo_display,
      repo_remote: Enum.find_value(streams, & &1.repo_remote),
      repo_aliases: repo_identity_aliases(streams),
      base_branch: first.base_branch,
      solo_session_count: Enum.sum(Enum.map(streams, & &1.solo_session_count))
    }
  end

  defp preferred_stream_repo(streams) do
    streams
    |> Enum.map(& &1.repo)
    |> Enum.uniq()
    |> Enum.sort_by(&{String.contains?(&1, "/"), String.downcase(&1)})
    |> hd()
  end

  defp cards(repo, sessions, repo_identity_catalog) do
    session_ids = Enum.map(sessions, & &1.id)

    with {:ok, entry_counts} <- entry_counts(repo, session_ids),
         {:ok, latest_entries} <- latest_entries(repo, session_ids),
         {:ok, active_blocker_counts} <- active_blocker_counts(repo, session_ids) do
      cards =
        Enum.map(sessions, fn %SoloSession{} = session ->
          card(
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

  defp entry_counts(_repo, []), do: {:ok, %{}}

  defp entry_counts(repo, session_ids) do
    rows =
      session_ids
      |> Enum.chunk_every(@query_chunk_size)
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

  defp active_blocker_counts(_repo, []), do: {:ok, %{}}

  defp active_blocker_counts(repo, session_ids) do
    entries =
      session_ids
      |> Enum.chunk_every(@query_chunk_size)
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

  defp latest_entries(_repo, []), do: {:ok, %{}}

  defp latest_entries(repo, session_ids) do
    entries =
      session_ids
      |> Enum.chunk_every(@query_chunk_size)
      |> Enum.flat_map(fn chunk -> repo.all(latest_entries_query(chunk)) end)

    {:ok, Map.new(entries, &{&1.solo_session_id, entry(&1)})}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp latest_entries_query(session_ids) do
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

  defp card(%SoloSession{} = session, entry_counts, latest_entry, active_blocker_count, repo_identity_catalog) do
    %{
      id: session.id,
      title: title(session),
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

  defp session_payload(%SoloSession{} = session, repo_identity_catalog) do
    %{
      id: session.id,
      title: title(session),
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

  defp title(%SoloSession{title: title, id: id}) do
    title
    |> redacted_text()
    |> present_text()
    |> Kernel.||(id)
  end

  defp entry(entry) when is_map(entry) do
    %{
      kind: Map.get(entry, :entry_kind),
      kind_label: status_label(Map.get(entry, :entry_kind)),
      status: Map.get(entry, :status),
      title: entry |> Map.get(:title) |> redacted_text() |> snippet(@snippet_limit),
      body: entry |> Map.get(:body) |> redacted_text() |> snippet(@snippet_limit),
      payload: entry |> Map.get(:payload) |> redacted_payload(),
      created_at: entry |> Map.get(:created_at) |> timestamp()
    }
  end

  defp detail_entry(%SoloSessionEntry{} = entry) do
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

  defp repo_identity_catalog_from_repo(repo, opts, repo_values) do
    case Keyword.fetch(opts, :repo_identity_catalog) do
      {:ok, repo_identity_catalog} ->
        {:ok, repo_identity_catalog}

      :error ->
        {:ok, build_repo_identity_catalog(repo_identity_repo_values(repo) ++ repo_values)}
    end
  end

  defp repo_identity_catalog_from_opts(opts, repo_values) do
    Keyword.get_lazy(opts, :repo_identity_catalog, fn -> build_repo_identity_catalog(repo_values) end)
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

  defp build_repo_identity_catalog(repo_values) do
    RepoIdentity.catalog(repo_values, trusted_remotes: configured_trusted_repo_remotes())
  end

  defp configured_trusted_repo_remotes do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
    |> Enum.uniq()
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

  defp redacted_text(value), do: Sanitizer.redacted_text(value)
  defp timestamp(value), do: Sanitizer.timestamp(value)
end
