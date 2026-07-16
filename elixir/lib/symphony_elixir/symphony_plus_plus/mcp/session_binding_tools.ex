defmodule SymphonyElixir.SymphonyPlusPlus.MCP.SessionBindingTools do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  import SymphonyElixir.SymphonyPlusPlus.MCP.ToolArguments,
    only: [optional_string_argument: 3]

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService

  alias SymphonyElixir.SymphonyPlusPlus.MCP.{
    Auth,
    Config,
    LocalClaimLeases,
    Server,
    Session,
    ToolCatalog
  }

  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @assignment_release_tool ToolCatalog.assignment_release_tool()
  @local_assignment_claim_tool ToolCatalog.local_assignment_claim_tool()
  @local_architect_assignment_claim_tool ToolCatalog.local_architect_assignment_claim_tool()
  @worker_tools ToolCatalog.worker_tools()
  @architect_tools ToolCatalog.architect_tools()
  @local_assignment_claim_stale_after_ms :timer.minutes(5)

  @spec release_current_assignment(map(), Server.t()) :: {:ok, map(), Server.t()} | term()
  def release_current_assignment(arguments, %Server{session: nil} = server) do
    with {:ok, reason} <- optional_string_argument(arguments, "reason", @assignment_release_tool) do
      reason = Redactor.redact_text(reason)

      result = %{
        "action" => @assignment_release_tool,
        "status" => "ok",
        "binding_cleared" => true,
        "solo_tools_available" => true,
        "fresh_mcp_session_required" => false,
        "released_assignment" => nil,
        "claim_lease_release" => %{"status" => "skipped", "reason" => "not_bound"},
        "recovery" => %{
          "next_action" => "retry_solo_tool",
          "fresh_mcp_session_required" => false,
          "release_reason" => reason
        }
      }

      {:ok, result, %{server | session_refresh_required: false}}
    end
  end

  def release_current_assignment(arguments, %Server{config: %Config{} = config, session: %Session{} = session} = server) do
    with {:ok, reason} <- optional_string_argument(arguments, "reason", @assignment_release_tool) do
      reason = Redactor.redact_text(reason)
      context = current_assignment_context(config.repo, session)
      {lease_release, released_context, binding_cleared?} = release_current_assignment_lease(config.repo, session, reason, context)
      fresh_mcp_session_required? = release_requires_fresh_session?(lease_release, binding_cleared?)

      result = %{
        "action" => @assignment_release_tool,
        "status" => if(binding_cleared?, do: "ok", else: "blocked"),
        "binding_cleared" => binding_cleared?,
        "solo_tools_available" => binding_cleared?,
        "fresh_mcp_session_required" => fresh_mcp_session_required?,
        "released_assignment" => released_context,
        "claim_lease_release" => lease_release,
        "recovery" => %{
          "next_action" => release_recovery_next_action(binding_cleared?, fresh_mcp_session_required?),
          "fresh_mcp_session_required" => fresh_mcp_session_required?
        }
      }

      updated_server =
        if binding_cleared?,
          do: %{server | session: nil, session_refresh_required: false},
          else: %{server | session_refresh_required: server.session_refresh_required or fresh_mcp_session_required?}

      {:ok, result, updated_server}
    end
  end

  @spec current_assignment_context(Server.t()) :: map()
  def current_assignment_context(%Server{config: %Config{repo: repo}, session: %Session{} = session}) do
    current_assignment_context(repo, session)
  end

  @spec current_assignment_context(module(), Session.t()) :: map()
  def current_assignment_context(repo, %Session{assignment: assignment} = session) do
    package_context = assignment_work_package_context(repo, assignment.work_package_id)
    repo_scope = assignment_repo_scope(assignment)

    %{
      "role" => assignment.grant_role,
      "work_package_id" => assignment.work_package_id,
      "phase_id" => assignment.phase_id,
      "claimed_by" => assignment.claimed_by
    }
    |> optional_put("repo", package_context["repo"] || repo_scope["repo"])
    |> optional_put("base_branch", package_context["base_branch"] || repo_scope["base_branch"])
    |> optional_put("work_request_id", assignment_work_request_id(repo, assignment))
    |> put_safe_claim_lease(repo, session)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec current_assignment_summary(module(), Session.t()) :: map()
  def current_assignment_summary(repo, %Session{assignment: assignment}) do
    package_context = assignment_work_package_context(repo, assignment.work_package_id)
    repo_scope = assignment_repo_scope(assignment)

    %{
      "grant_role" => assignment.grant_role,
      "work_package_id" => assignment.work_package_id,
      "claimed_by" => assignment.claimed_by,
      "phase_id" => assignment.phase_id
    }
    |> optional_put("repo", package_context["repo"] || repo_scope["repo"])
    |> optional_put("base_branch", package_context["base_branch"] || repo_scope["base_branch"])
    |> optional_put("work_request_id", assignment_work_request_id(repo, assignment))
    |> drop_nil_values()
  end

  @spec require_current_session_claim_for_bound_call(Server.t(), String.t(), map()) :: {:ok, Server.t()} | term()
  def require_current_session_claim_for_bound_call(%Server{} = server, method, params) do
    if bound_session_call?(server, method, params) do
      require_current_session_claim(server)
    else
      {:ok, server}
    end
  end

  defp release_current_assignment_lease(repo, %Session{} = session, reason, context) do
    case current_matching_claim_lease(repo, session) do
      {:ok, %ClaimLease{} = lease} ->
        release_matching_claim_lease(repo, lease, reason, context)

      {:error, reason} ->
        binding_cleared? = claim_lease_error_allows_binding_clear?(reason)
        status = if binding_cleared?, do: "skipped", else: "not_released"
        {%{"status" => status, "reason" => reason_text(reason)}, context, binding_cleared?}
    end
  rescue
    _error -> {%{"status" => "not_released", "reason" => "ledger_unavailable"}, context, false}
  end

  defp release_matching_claim_lease(repo, %ClaimLease{} = lease, reason, context) do
    case ClaimLeaseService.release(repo, lease.id, reason: reason) do
      {:ok, %ClaimLease{} = released} ->
        release = %{
          "status" => "released",
          "claim_lease_id" => released.id,
          "claim_lease_status" => released.status
        }

        {release, context_with_claim_lease(context, released), true}

      {:error, :not_found} ->
        release = %{
          "status" => "skipped",
          "reason" => "not_found",
          "claim_lease_id" => lease.id
        }

        {release, context_with_claim_lease_status(context, lease.id, "not_found"), true}

      {:error, reason} ->
        binding_cleared? = claim_lease_error_allows_binding_clear?(reason)
        status = if binding_cleared?, do: "skipped", else: "not_released"

        {%{"status" => status, "reason" => reason_text(reason)}, context, binding_cleared?}
    end
  end

  defp release_requires_fresh_session?(%{"reason" => reason}, false)
       when reason in ["claim_lease_identity_unavailable", "claim_stale", "claim_lease_mismatch"],
       do: true

  defp release_requires_fresh_session?(_lease_release, _binding_cleared?), do: false

  defp release_recovery_next_action(true, _fresh_mcp_session_required?), do: "retry_solo_tool"
  defp release_recovery_next_action(false, true), do: "start_fresh_mcp_session"
  defp release_recovery_next_action(false, false), do: "retry_release_current_assignment"

  defp claim_lease_error_allows_binding_clear?(reason) do
    reason in [:not_applicable, :not_found, :claim_stale, :claim_lease_mismatch, :claim_lease_identity_unavailable]
  end

  defp assignment_work_package_context(repo, work_package_id) when is_binary(work_package_id) do
    case WorkPackageRepository.get(repo, work_package_id) do
      {:ok, %WorkPackage{} = work_package} ->
        %{"repo" => work_package.repo, "base_branch" => work_package.base_branch}

      _result ->
        %{}
    end
  rescue
    _error -> %{}
  end

  defp assignment_work_package_context(_repo, _work_package_id), do: %{}

  defp assignment_repo_scope(%{scopes: scopes}) when is_list(scopes) do
    case Enum.find(scopes, &match?(%Scope{type: :repo}, &1)) do
      %Scope{} = scope -> %{"repo" => scope.repo, "base_branch" => scope.base_branch}
      nil -> %{}
    end
  end

  defp assignment_repo_scope(_assignment), do: %{}

  defp assignment_work_request_id(repo, %{scopes: scopes, work_package_id: work_package_id}) do
    work_request_scope_id(scopes) || work_request_id_for_work_package(repo, work_package_id)
  end

  defp work_request_scope_id(scopes) when is_list(scopes) do
    case Enum.find(scopes, &match?(%Scope{type: :work_request, id: id} when is_binary(id), &1)) do
      %Scope{id: id} -> id
      nil -> nil
    end
  end

  defp work_request_scope_id(_scopes), do: nil

  defp work_request_id_for_work_package(repo, work_package_id) when is_binary(work_package_id) do
    query =
      from(work_package in WorkPackage,
        where: work_package.id == ^work_package_id,
        order_by: [asc: work_package.inserted_at, asc: work_package.id],
        select: work_package.work_request_id,
        limit: 1
      )

    case repo.one(query) do
      work_request_id when is_binary(work_request_id) -> work_request_id
      _value -> nil
    end
  rescue
    _error -> nil
  end

  defp work_request_id_for_work_package(_repo, _work_package_id), do: nil

  defp put_safe_claim_lease(context, repo, %Session{} = session) do
    case current_matching_claim_lease(repo, session) do
      {:ok, %ClaimLease{} = lease} -> context_with_claim_lease(context, lease)
      {:error, _reason} -> context
    end
  rescue
    _error -> context
  end

  defp context_with_claim_lease(context, %ClaimLease{} = lease) do
    context
    |> Map.put("claim_lease_id", lease.id)
    |> Map.put("claim_lease_status", lease.status)
  end

  defp context_with_claim_lease_status(context, claim_lease_id, status) do
    context
    |> Map.put("claim_lease_id", claim_lease_id)
    |> Map.put("claim_lease_status", status)
  end

  defp current_matching_claim_lease(_repo, %Session{assignment: %{work_package_id: work_package_id}}) when not is_binary(work_package_id),
    do: {:error, :not_applicable}

  defp current_matching_claim_lease(
         repo,
         %Session{
           assignment: assignment,
           claim_lease_id: claim_lease_id,
           claim_actor_kind: actor_kind,
           claim_actor_id: actor_id,
           claim_actor_display_name: actor_display_name
         }
       )
       when is_binary(claim_lease_id) and is_binary(actor_kind) and is_binary(actor_id) do
    work_package_id = assignment.work_package_id

    case ClaimLeaseService.current_for_work_package(repo, work_package_id) do
      {:ok, %ClaimLease{} = lease} ->
        require_current_session_claim_lease(lease, assignment, claim_lease_id, actor_kind, actor_id, actor_display_name)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_matching_claim_lease(repo, %Session{assignment: %{work_package_id: work_package_id}}) when is_binary(work_package_id) do
    case ClaimLeaseService.current_for_work_package(repo, work_package_id) do
      {:error, :not_found} -> {:error, :not_found}
      {:ok, %ClaimLease{}} -> {:error, :claim_lease_identity_unavailable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_matching_claim_lease(_repo, %Session{}), do: {:error, :claim_lease_identity_unavailable}

  defp require_current_session_claim_lease(
         %ClaimLease{} = lease,
         assignment,
         claim_lease_id,
         actor_kind,
         actor_id,
         actor_display_name
       ) do
    cond do
      lease.id != claim_lease_id ->
        {:error, :claim_lease_mismatch}

      lease.work_package_id != assignment.work_package_id ->
        {:error, :claim_lease_mismatch}

      claim_lease_assignment_mismatch?(lease, assignment) ->
        {:error, :claim_lease_mismatch}

      lease.actor_kind != actor_kind ->
        {:error, :claim_lease_mismatch}

      lease.actor_id != actor_id ->
        {:error, :claim_lease_mismatch}

      lease.actor_display_name != actor_display_name ->
        {:error, :claim_lease_mismatch}

      true ->
        {:ok, lease}
    end
  end

  defp claim_lease_assignment_mismatch?(%ClaimLease{} = lease, assignment) do
    is_binary(lease.access_grant_id) and
      is_binary(assignment.grant_id) and
      lease.access_grant_id != assignment.grant_id
  end

  defp bound_session_call?(%Server{session: %Session{claim_lease_id: claim_lease_id}}, "tools/call", %{"name" => name})
       when name in @worker_tools or name in @architect_tools,
       do: is_binary(claim_lease_id)

  defp bound_session_call?(%Server{session: %Session{claim_lease_id: claim_lease_id}}, "resources/read", %{
         "uri" => "sympp://assignment/current"
       }),
       do: is_binary(claim_lease_id)

  defp bound_session_call?(%Server{session: %Session{claim_lease_id: claim_lease_id}}, "resources/read", %{
         "uri" => "sympp://work-packages/" <> _path
       }),
       do: is_binary(claim_lease_id)

  defp bound_session_call?(%Server{}, _method, _params), do: false

  defp require_current_session_claim(%Server{config: %Config{repo: repo}, session: %Session{} = session} = server) do
    case {Auth.require_live_session_grant(session, repo), current_matching_claim_lease(repo, session)} do
      {:ok, {:ok, %ClaimLease{status: "active"} = lease}} -> refresh_current_session_claim_lease(repo, server, lease)
      {:ok, {:ok, %ClaimLease{status: "paused"}}} -> lost_current_session_claim(server, :claim_lease_paused)
      {:ok, {:ok, %ClaimLease{}}} -> lost_current_session_claim(server, :claim_lease_not_active)
      {:ok, {:error, reason}} -> lost_current_session_claim(server, reason)
      {{:error, reason}, _claim_lease} -> lost_current_session_claim(server, reason)
    end
  rescue
    _error -> lost_current_session_claim(server, :claim_lease_check_failed)
  end

  defp refresh_current_session_claim_lease(repo, %Server{session: %Session{} = session} = server, %ClaimLease{} = lease) do
    case ClaimLeaseService.heartbeat(repo, lease.id, stale_after_ms: @local_assignment_claim_stale_after_ms) do
      {:ok, %ClaimLease{} = renewed} ->
        {:ok, %{server | session: Session.with_claim_lease(session, renewed)}}

      {:error, :claim_stale} ->
        reclaim_current_session_claim_lease(repo, server, session, lease)

      {:error, reason} ->
        lost_current_session_claim(server, reason)
    end
  end

  defp reclaim_current_session_claim_lease(repo, %Server{} = server, %Session{} = session, %ClaimLease{} = lease) do
    actor = %{
      "actor_kind" => session.claim_actor_kind,
      "actor_id" => session.claim_actor_id,
      "actor_display_name" => session.claim_actor_display_name
    }

    opts = LocalClaimLeases.reclaim_opts("mcp_session_tool_heartbeat_stale", @local_assignment_claim_stale_after_ms)

    case ClaimLeaseService.reclaim_stale(repo, lease.work_package_id, actor, opts) do
      {:ok, %ClaimLease{} = replacement} -> {:ok, %{server | session: Session.with_claim_lease(session, replacement)}}
      {:error, reason} -> lost_current_session_claim(server, reason)
    end
  end

  defp lost_current_session_claim(%Server{session: %Session{} = session} = server, reason) do
    action =
      case session.assignment.grant_role do
        "architect" -> @local_architect_assignment_claim_tool
        _role -> @local_assignment_claim_tool
      end

    updated_server = %{server | session: nil, session_refresh_required: true}

    {:error, -32_001, "Unauthorized",
     %{
       "reason" => if(Auth.live_grant_loss_reason?(reason), do: reason_text(reason), else: "claim_lease_lost"),
       "claim_lease_reason" => reason_text(reason),
       "action" => action
     }, updated_server}
  end

  defp optional_put(attrs, _key, nil), do: attrs
  defp optional_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp drop_nil_values(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
