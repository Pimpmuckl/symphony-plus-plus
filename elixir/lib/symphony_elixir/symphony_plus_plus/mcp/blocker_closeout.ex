defmodule SymphonyElixir.SymphonyPlusPlus.MCP.BlockerCloseout do
  @moduledoc false

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [
      optional_object_argument: 2,
      optional_string_argument: 2,
      optional_string_list_argument: 2,
      required_argument: 2
    ]

  alias SymphonyElixir.SymphonyPlusPlus.Dashboard.BlockerProjection
  alias SymphonyElixir.SymphonyPlusPlus.MCP.Session
  alias SymphonyElixir.SymphonyPlusPlus.MCP.ToolCatalog
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Repository, as: PlanningRepository

  @blocker_closeout_decisions ToolCatalog.blocker_closeout_decisions()

  @type repo :: module()
  @type result :: {:ok, term()} | {:tool_error, term()} | {:error, term()}

  @spec prepare_scoped(repo(), Session.t(), [String.t() | nil], map(), String.t()) :: result()
  def prepare_scoped(repo, %Session{}, work_package_ids, arguments, tool) do
    with {:ok, closeout} <- optional_blocker_closeout_argument(arguments),
         {:ok, active_blockers} <- active_blockers_for_work_packages(repo, work_package_ids) do
      cond do
        active_blockers == [] ->
          {:ok, :not_needed}

        is_nil(closeout) ->
          {:tool_error, {:blocker_closeout_required, active_blocker_payloads(active_blockers)}}

        true ->
          prepare_active_blocker_closeout(active_blockers, closeout, tool)
      end
    end
  end

  @spec decision(term()) :: String.t() | nil
  def decision(%{closeout: %{decision: decision}}), do: decision
  def decision(:not_needed), do: nil

  @spec apply(repo(), Session.t(), term()) :: result()
  def apply(_repo, %Session{}, :not_needed), do: {:ok, blocker_closeout_not_needed()}

  def apply(repo, %Session{} = session, %{active_blockers: active_blockers, closeout: closeout, tool: tool}) do
    apply_blocker_closeout_decision(repo, session, active_blockers, closeout, tool)
  end

  defp prepare_active_blocker_closeout(active_blockers, closeout, tool) do
    with :ok <- require_blocker_closeout_covers_active_blockers(active_blockers, closeout.blocker_ids) do
      {:ok, %{active_blockers: active_blockers, closeout: closeout, tool: tool}}
    end
  end

  defp optional_blocker_closeout_argument(arguments) do
    with {:ok, closeout} <- optional_object_argument(arguments, "blocker_closeout") do
      normalize_blocker_closeout(closeout)
    end
  end

  defp normalize_blocker_closeout(nil), do: {:ok, nil}

  defp normalize_blocker_closeout(closeout) when is_map(closeout) do
    with {:ok, decision} <- required_argument(closeout, "decision"),
         :ok <- require_blocker_closeout_decision(decision),
         {:ok, blocker_ids} <- optional_string_list_argument(closeout, "blocker_ids"),
         {:ok, resolution} <- optional_string_argument(closeout, "resolution"),
         {:ok, summary} <- optional_string_argument(closeout, "summary"),
         :ok <- require_blocker_closeout_resolution(decision, resolution) do
      {:ok, %{decision: decision, blocker_ids: blocker_ids, resolution: resolution, summary: summary}}
    end
  end

  defp require_blocker_closeout_decision(decision) do
    if decision in @blocker_closeout_decisions, do: :ok, else: {:tool_error, "invalid_blocker_closeout_decision"}
  end

  defp require_blocker_closeout_resolution("resolved", resolution) when is_binary(resolution), do: :ok
  defp require_blocker_closeout_resolution("resolved", _resolution), do: {:tool_error, "missing_blocker_closeout_resolution"}
  defp require_blocker_closeout_resolution("still_active", _resolution), do: :ok

  defp apply_blocker_closeout_decision(repo, %Session{} = session, active_blockers, closeout, tool) do
    with :ok <- require_blocker_closeout_covers_active_blockers(active_blockers, closeout.blocker_ids) do
      case closeout.decision do
        "resolved" -> resolve_active_blockers(repo, session, active_blockers, closeout, tool)
        "still_active" -> preserve_active_blockers(repo, session, active_blockers, closeout, tool)
      end
    end
  end

  defp require_blocker_closeout_covers_active_blockers(_active_blockers, []), do: :ok

  defp require_blocker_closeout_covers_active_blockers(active_blockers, blocker_ids) do
    active_ids = active_blockers |> Enum.map(& &1.id) |> Enum.sort()
    requested_ids = Enum.sort(blocker_ids)

    if requested_ids == active_ids do
      :ok
    else
      {:tool_error, {:blocker_closeout_scope_mismatch, active_ids, requested_ids}}
    end
  end

  defp resolve_active_blockers(repo, %Session{} = session, active_blockers, closeout, tool) do
    with {:ok, events} <-
           append_blocker_closeout_events(active_blockers, fn blocker ->
             append_blocker_closeout_resolution(repo, session, blocker, closeout, tool)
           end) do
      {:ok,
       %{
         "decision" => "resolved",
         "active_blockers_before" => active_blocker_payloads(active_blockers),
         "resolved_blocker_ids" => Enum.map(active_blockers, & &1.id),
         "progress_event_ids" => events |> Enum.reverse() |> Enum.map(& &1.id)
       }}
    end
  end

  defp preserve_active_blockers(repo, %Session{} = session, active_blockers, closeout, tool) do
    with {:ok, events} <-
           append_blocker_closeout_events(active_blockers, fn blocker ->
             append_blocker_closeout_preservation(repo, session, blocker, closeout, tool)
           end) do
      {:ok,
       %{
         "decision" => "still_active",
         "active_blockers" => active_blocker_payloads(active_blockers),
         "progress_event_ids" => events |> Enum.reverse() |> Enum.map(& &1.id)
       }}
    end
  end

  defp append_blocker_closeout_events(active_blockers, append_fun) do
    Enum.reduce_while(active_blockers, {:ok, []}, fn blocker, {:ok, events} ->
      append_blocker_closeout_event(append_fun, blocker, events)
    end)
  end

  defp append_blocker_closeout_event(append_fun, blocker, events) do
    case append_fun.(blocker) do
      {:ok, event} -> {:cont, {:ok, [event | events]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp append_blocker_closeout_resolution(repo, %Session{} = session, blocker, closeout, tool) do
    PlanningRepository.append_audit_progress_event_for_work_package(
      repo,
      session.assignment,
      blocker.work_package_id,
      %{
        "summary" => closeout.summary || "Resolved blocker during #{tool}",
        "body" => closeout.resolution,
        "status" => "resolved",
        "idempotency_key" => blocker_closeout_idempotency_key(tool, blocker, "resolved"),
        "payload" => %{
          "type" => "blocker",
          "source_tool" => "resolve_blocker",
          "blocker_id" => blocker.id,
          "resolution" => closeout.resolution,
          "active" => false,
          "closeout_tool" => tool
        }
      }
    )
  end

  defp append_blocker_closeout_preservation(repo, %Session{} = session, blocker, closeout, tool) do
    PlanningRepository.append_audit_progress_event_for_work_package(
      repo,
      session.assignment,
      blocker.work_package_id,
      %{
        "summary" => closeout.summary || "Preserved active blocker during #{tool}",
        "body" => closeout.resolution || blocker.body || blocker.summary,
        "status" => "blocked",
        "idempotency_key" => blocker_closeout_idempotency_key(tool, blocker, "still_active"),
        "payload" => %{
          "type" => "blocker_closeout_decision",
          "source_tool" => tool,
          "blocker_id" => blocker.id,
          "decision" => "still_active"
        }
      }
    )
  end

  defp blocker_closeout_idempotency_key(tool, blocker, decision) do
    ["blocker_closeout", tool, blocker.work_package_id, blocker.id, blocker.event_id, decision]
    |> Enum.join(":")
  end

  defp active_blockers_for_work_packages(repo, work_package_ids) do
    work_package_ids =
      work_package_ids
      |> Enum.filter(&filled_string?/1)
      |> Enum.uniq()

    Enum.reduce_while(work_package_ids, {:ok, []}, fn work_package_id, {:ok, blockers} ->
      case active_blockers_for_work_package(repo, work_package_id) do
        {:ok, package_blockers} -> {:cont, {:ok, blockers ++ package_blockers}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp active_blockers_for_work_package(repo, work_package_id) do
    with {:ok, progress_events} <- PlanningRepository.list_progress_events(repo, work_package_id) do
      blockers =
        progress_events
        |> BlockerProjection.blockers()
        |> Enum.filter(& &1.active)
        |> Enum.map(&Map.put(&1, :work_package_id, work_package_id))

      {:ok, blockers}
    end
  end

  defp active_blocker_payloads(blockers), do: Enum.map(blockers, &active_blocker_payload/1)

  defp active_blocker_payload(blocker) do
    %{
      "blocker_id" => blocker.id,
      "work_package_id" => blocker.work_package_id,
      "summary" => blocker.summary,
      "body" => blocker.body,
      "status" => blocker.status,
      "updated_at" => blocker.updated_at
    }
  end

  defp blocker_closeout_not_needed, do: %{"decision" => "none", "active_blockers" => []}

  defp filled_string?(value), do: is_binary(value) and String.trim(value) != ""
end
