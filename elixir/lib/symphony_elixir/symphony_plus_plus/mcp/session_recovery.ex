defmodule SymphonyElixir.SymphonyPlusPlus.MCP.SessionRecovery do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service, as: ClaimLeaseService
  alias SymphonyElixir.SymphonyPlusPlus.MCP.{Auth, Config, HTTPStateStore, Repository, Server, Session, SessionBinding}

  @ttl_ms 86_400_000
  @heartbeat_ms :timer.hours(1)
  @cleanup_interval_ms :timer.hours(1)
  @lease_stale_after_ms :timer.minutes(5)
  @release_current_assignment_tool "release_current_assignment"
  @local_claim_tools ["claim_local_assignment", "claim_local_architect_assignment"]
  @session_claim_tools @local_claim_tools

  @spec remember(Config.t(), String.t(), String.t(), term(), Server.t(), term()) :: :ok
  def remember(%Config{mode: :http, repo: repo} = config, client_key, state_key, payload, %Server{} = server, response)
      when is_atom(repo) and is_binary(client_key) and is_binary(state_key) do
    case Repository.ensure_migrated(repo) do
      :ok ->
        result = persist_action(config, repo, remember_action(config, client_key, state_key, payload, server, response))

        maybe_cleanup_stale(config, repo)
        result

      _error ->
        :ok
    end
  rescue
    _error -> :ok
  end

  def remember(%Config{}, _client_key, _state_key, _payload, %Server{}, _response), do: :ok

  defp persist_action(config, repo, {:upsert, attrs}) do
    :ok = upsert(repo, attrs)
    HTTPStateStore.defer_recovery_persistence(config, Map.fetch!(attrs, :id), @heartbeat_ms)
  end

  defp persist_action(config, repo, {:touch, id, now}) do
    HTTPStateStore.persist_recovery_if_due(config, id, @heartbeat_ms, fn -> touch(repo, id, now) end)
  end

  defp persist_action(_config, _repo, :skip), do: :ok

  @spec rehydrate(Config.t(), String.t(), String.t()) :: {:ok, Server.t()} | :not_found
  def rehydrate(%Config{mode: :http, repo: repo} = config, client_key, state_key)
      when is_atom(repo) and is_binary(client_key) and is_binary(state_key) do
    with :ok <- Repository.ensure_migrated(repo),
         :ok <- maybe_cleanup_stale(config, repo),
         {:ok, %SessionBinding{} = binding} <- get_binding(repo, client_key, state_key),
         :ok <- require_fresh(binding),
         :ok <- persist_action(config, repo, {:touch, binding.id, now()}) do
      case recover_session(repo, binding) do
        {:ok, %Session{} = session} ->
          {:ok, Server.new(config, initialized: true, local_daemon_trusted: config.local_daemon_trusted, session: session, state_key: state_key)}

        {:error, _reason} ->
          {:ok, Server.new(config, initialized: true, local_daemon_trusted: config.local_daemon_trusted, state_key: state_key)}
      end
    else
      _error -> :not_found
    end
  rescue
    _error -> :not_found
  end

  def rehydrate(%Config{}, _client_key, _state_key), do: :not_found

  defp remember_action(_config, client_key, state_key, payload, %Server{initialized: true, session: nil} = server, response) do
    cond do
      initialize_request?(payload) ->
        remember_unbound_initialized(client_key, state_key, nil)

      release_current_assignment_success?(payload, response, server) ->
        remember_unbound_initialized(client_key, state_key, @release_current_assignment_tool)

      true ->
        {:touch, SessionBinding.binding_id(client_key, state_key), now()}
    end
  end

  defp remember_action(config, client_key, state_key, payload, %Server{initialized: true, session: %Session{} = session} = server, response) do
    case claim_tool_name(payload, response, session) do
      tool_name when tool_name in @local_claim_tools ->
        remember_session_claim(config, client_key, state_key, session, response, tool_name)

      :ambiguous_claim ->
        remember_nonrecoverable_claim(client_key, state_key, session, "ambiguous_claim")

      _tool_name ->
        if release_current_assignment_success?(payload, response, server) do
          remember_unbound_initialized(client_key, state_key, @release_current_assignment_tool)
        else
          {:touch, SessionBinding.binding_id(client_key, state_key), now()}
        end
    end
  end

  defp remember_action(_config, _client_key, _state_key, _payload, %Server{}, _response), do: :skip

  defp remember_session_claim(%Config{repo: repo}, client_key, state_key, %Session{} = session, response, tool_name) do
    case session_claim_lease(repo, session, response) do
      {:ok, %ClaimLease{} = lease} ->
        now = now()

        {:upsert,
         client_key
         |> session_attrs(state_key, session, now)
         |> Map.merge(%{
           recoverable: true,
           recovery_kind: tool_name,
           claim_lease_id: lease.id,
           actor_kind: lease.actor_kind,
           actor_id: lease.actor_id,
           actor_display_name: lease.actor_display_name,
           last_rehydrated_at: nil
         })}

      _error ->
        if tool_name in @local_claim_tools do
          remember_unbound_initialized(client_key, state_key, tool_name)
        else
          remember_nonrecoverable_claim(client_key, state_key, session, tool_name)
        end
    end
  end

  defp session_claim_lease(repo, %Session{} = session, _response), do: current_session_claim_lease(repo, session)

  defp current_session_claim_lease(
         repo,
         %Session{
           assignment: %{work_package_id: work_package_id},
           claim_lease_id: claim_lease_id,
           claim_actor_kind: actor_kind,
           claim_actor_id: actor_id,
           claim_actor_display_name: actor_display_name
         }
       )
       when is_binary(work_package_id) and is_binary(claim_lease_id) and is_binary(actor_kind) and
              is_binary(actor_id) do
    with {:ok, %ClaimLease{} = lease} <- ClaimLeaseService.current_for_work_package(repo, work_package_id),
         :ok <- require_session_lease_identity(lease, claim_lease_id, actor_kind, actor_id, actor_display_name) do
      {:ok, lease}
    end
  end

  defp current_session_claim_lease(_repo, %Session{}), do: {:error, :missing_claim_lease_scope}

  defp remember_nonrecoverable_claim(client_key, state_key, %Session{} = session, tool_name) do
    now = now()

    {:upsert,
     client_key
     |> session_attrs(state_key, session, now)
     |> Map.merge(%{
       recoverable: false,
       recovery_kind: tool_name,
       claim_lease_id: nil,
       actor_kind: nil,
       actor_id: nil,
       actor_display_name: nil,
       last_rehydrated_at: nil
     })}
  end

  defp remember_unbound_initialized(client_key, state_key, recovery_kind) do
    now = now()

    {:upsert,
     client_key
     |> base_attrs(state_key, now)
     |> Map.merge(%{
       initialized: true,
       recoverable: false,
       recovery_kind: recovery_kind,
       access_grant_id: nil,
       claim_lease_id: nil,
       work_package_id: nil,
       phase_id: nil,
       grant_role: nil,
       claimed_by: nil,
       actor_kind: nil,
       actor_id: nil,
       actor_display_name: nil,
       last_rehydrated_at: nil
     })}
  end

  defp recover_session(_repo, %SessionBinding{recoverable: false}), do: {:error, :claim_required}

  defp recover_session(repo, %SessionBinding{} = binding) do
    with {:ok, %AccessGrant{} = grant} <- AccessGrantRepository.get(repo, binding.access_grant_id),
         :ok <- require_grant_matches_binding(grant, binding),
         :ok <- AccessGrantService.require_live_package_authority(repo, grant),
         {:ok, %ClaimLease{} = lease} <- recover_claim_lease(repo, binding),
         {:ok, %Session{} = session} <- Auth.session_from_grant(repo, grant, proof_hash: grant.secret_hash),
         :ok <- require_session_matches_binding(session, binding) do
      mark_rehydrated(repo, binding, lease)
      {:ok, Session.with_claim_lease(session, lease)}
    else
      _error -> {:error, :reclaim_required}
    end
  end

  defp recover_claim_lease(repo, %SessionBinding{work_package_id: work_package_id} = binding) when is_binary(work_package_id) do
    with {:ok, %ClaimLease{} = lease} <- ClaimLeaseService.current_for_work_package(repo, work_package_id),
         :ok <- require_lease_matches_binding(lease, binding) do
      renew_or_reclaim_lease(repo, lease, binding)
    end
  end

  defp recover_claim_lease(_repo, %SessionBinding{}), do: {:error, :missing_work_package_id}

  defp renew_or_reclaim_lease(repo, %ClaimLease{status: "active"} = lease, %SessionBinding{} = binding) do
    if ClaimLease.stale?(lease, now(), @lease_stale_after_ms) do
      reclaim_lease(repo, lease.work_package_id, binding, "mcp_session_rehydrate_stale")
    else
      case ClaimLeaseService.heartbeat(repo, lease.id, stale_after_ms: @lease_stale_after_ms) do
        {:ok, %ClaimLease{} = renewed} -> {:ok, renewed}
        {:error, :claim_stale} -> reclaim_lease(repo, lease.work_package_id, binding, "mcp_session_rehydrate_stale")
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp renew_or_reclaim_lease(_repo, %ClaimLease{}, %SessionBinding{}), do: {:error, :claim_lease_not_active}

  defp reclaim_lease(repo, work_package_id, %SessionBinding{} = binding, reason) do
    ClaimLeaseService.reclaim_stale(repo, work_package_id, actor(binding),
      reason: reason,
      current_stale_after_ms: @lease_stale_after_ms,
      stale_after_ms: @lease_stale_after_ms
    )
  end

  defp require_grant_matches_binding(%AccessGrant{} = grant, %SessionBinding{} = binding) do
    cond do
      grant.id != binding.access_grant_id -> {:error, :grant_mismatch}
      grant.work_package_id != binding.work_package_id -> {:error, :work_package_mismatch}
      grant.phase_id != binding.phase_id -> {:error, :phase_mismatch}
      grant.grant_role != binding.grant_role -> {:error, :role_mismatch}
      grant.claimed_by != binding.claimed_by -> {:error, :claim_owner_mismatch}
      true -> :ok
    end
  end

  defp require_session_matches_binding(%Session{} = session, %SessionBinding{} = binding) do
    cond do
      session.assignment.grant_id != binding.access_grant_id -> {:error, :grant_mismatch}
      session.assignment.work_package_id != binding.work_package_id -> {:error, :work_package_mismatch}
      session.assignment.phase_id != binding.phase_id -> {:error, :phase_mismatch}
      session.assignment.grant_role != binding.grant_role -> {:error, :role_mismatch}
      session.assignment.claimed_by != binding.claimed_by -> {:error, :claim_owner_mismatch}
      true -> :ok
    end
  end

  defp require_lease_matches_binding(%ClaimLease{} = lease, %SessionBinding{} = binding) do
    cond do
      lease.work_package_id != binding.work_package_id -> {:error, :work_package_mismatch}
      lease.actor_kind != binding.actor_kind -> {:error, :actor_mismatch}
      lease.actor_id != binding.actor_id -> {:error, :actor_mismatch}
      lease.actor_display_name != binding.actor_display_name -> {:error, :actor_mismatch}
      true -> :ok
    end
  end

  defp require_session_lease_identity(
         %ClaimLease{} = lease,
         claim_lease_id,
         actor_kind,
         actor_id,
         actor_display_name
       ) do
    cond do
      lease.id != claim_lease_id -> {:error, :claim_lease_mismatch}
      lease.actor_kind != actor_kind -> {:error, :actor_mismatch}
      lease.actor_id != actor_id -> {:error, :actor_mismatch}
      lease.actor_display_name != actor_display_name -> {:error, :actor_mismatch}
      true -> :ok
    end
  end

  defp mark_rehydrated(repo, %SessionBinding{} = binding, %ClaimLease{} = lease) do
    now = now()

    upsert(repo, %{
      id: binding.id,
      client_key_hash: binding.client_key_hash,
      initialized: true,
      recoverable: true,
      recovery_kind: binding.recovery_kind,
      access_grant_id: binding.access_grant_id,
      claim_lease_id: lease.id,
      work_package_id: binding.work_package_id,
      phase_id: binding.phase_id,
      grant_role: binding.grant_role,
      claimed_by: binding.claimed_by,
      actor_kind: lease.actor_kind,
      actor_id: lease.actor_id,
      actor_display_name: lease.actor_display_name,
      last_seen_at: now,
      last_rehydrated_at: now
    })
  end

  defp upsert(repo, attrs) do
    attrs = normalize_datetimes(attrs)

    case repo.get(SessionBinding, Map.fetch!(attrs, :id)) do
      nil -> %SessionBinding{}
      %SessionBinding{} = binding -> binding
    end
    |> SessionBinding.changeset(attrs)
    |> then(fn changeset ->
      if changeset.data.__meta__.state == :built, do: repo.insert(changeset), else: repo.update(changeset)
    end)
    |> case do
      {:ok, %SessionBinding{}} -> :ok
      {:error, _reason} -> {:error, :persistence_failed}
    end
  end

  defp touch(repo, id, now) do
    case repo.get(SessionBinding, id) do
      %SessionBinding{} = binding ->
        binding
        |> SessionBinding.changeset(%{last_seen_at: now})
        |> repo.update()
        |> case do
          {:ok, %SessionBinding{}} -> :ok
          {:error, _reason} -> {:error, :persistence_failed}
        end

      nil ->
        {:error, :not_found}
    end
  end

  defp get_binding(repo, client_key, state_key) do
    case repo.get(SessionBinding, SessionBinding.binding_id(client_key, state_key)) do
      %SessionBinding{} = binding -> {:ok, binding}
      nil -> {:error, :not_found}
    end
  end

  defp release_current_assignment_success?(payloads, responses, %Server{}) when is_list(payloads) do
    Enum.any?(payloads, fn payload ->
      release_current_assignment_payload?(payload) and
        release_current_assignment_response_success?(response_for_payload(payload, responses))
    end)
  end

  defp release_current_assignment_success?(payload, response, %Server{}) do
    release_current_assignment_payload?(payload) and release_current_assignment_response_success?(response)
  end

  defp release_current_assignment_payload?(%{
         "jsonrpc" => "2.0",
         "method" => "tools/call",
         "params" => %{"name" => @release_current_assignment_tool}
       }),
       do: true

  defp release_current_assignment_payload?(_payload), do: false

  defp release_current_assignment_response_success?(%{"result" => %{"structuredContent" => %{"action" => @release_current_assignment_tool, "binding_cleared" => true}}}),
    do: true

  defp release_current_assignment_response_success?(nil), do: true
  defp release_current_assignment_response_success?(_response), do: false

  defp cleanup_stale(repo) do
    cutoff = DateTime.add(now(), -@ttl_ms, :millisecond)

    repo.delete_all(
      from(binding in SessionBinding,
        where: binding.last_seen_at < ^cutoff
      )
    )

    :ok
  rescue
    _error -> :ok
  end

  defp maybe_cleanup_stale(config, repo) do
    HTTPStateStore.cleanup_recovery_if_due(config, @cleanup_interval_ms, fn -> cleanup_stale(repo) end)
  end

  defp require_fresh(%SessionBinding{last_seen_at: %DateTime{} = last_seen_at}) do
    if DateTime.diff(now(), last_seen_at, :millisecond) <= @ttl_ms do
      :ok
    else
      {:error, :stale_binding}
    end
  end

  defp require_fresh(%SessionBinding{}), do: {:error, :stale_binding}

  defp session_attrs(client_key, state_key, %Session{} = session, %DateTime{} = now) do
    assignment = session.assignment

    base_attrs(client_key, state_key, now)
    |> Map.merge(%{
      initialized: true,
      access_grant_id: assignment.grant_id,
      work_package_id: assignment.work_package_id,
      phase_id: assignment.phase_id,
      grant_role: assignment.grant_role,
      claimed_by: assignment.claimed_by
    })
  end

  defp base_attrs(client_key, state_key, %DateTime{} = now) do
    %{
      id: SessionBinding.binding_id(client_key, state_key),
      client_key_hash: SessionBinding.client_key_hash(client_key),
      last_seen_at: now
    }
  end

  defp actor(%SessionBinding{} = binding) do
    %{
      "actor_kind" => binding.actor_kind,
      "actor_id" => binding.actor_id,
      "actor_display_name" => binding.actor_display_name
    }
  end

  defp initialize_request?(%{"method" => "initialize"}), do: true
  defp initialize_request?(_payload), do: false

  defp claim_tool_name(payloads, responses, %Session{} = session) when is_list(payloads) do
    candidates = Enum.map(payloads, &{&1, response_for_payload(&1, responses)})

    explicit_claim_tool_name(candidates, session) ||
      case claim_payload_count(candidates) do
        0 -> nil
        1 -> notification_claim_tool_name(candidates, session)
        _count -> :ambiguous_claim
      end
  end

  defp claim_tool_name(payload, response, %Session{} = session) do
    explicit_claim_tool_name([{payload, response}], session) || successful_claim_tool_name(payload, response) ||
      notification_claim_tool_name([{payload, response}], session)
  end

  defp explicit_claim_tool_name(candidates, %Session{} = session) do
    Enum.reduce(candidates, nil, fn {payload, response}, selected ->
      explicit_claim_tool_name(payload, response, session) || selected
    end)
  end

  defp explicit_claim_tool_name(
         %{"method" => "tools/call", "params" => %{"name" => name}},
         %{"result" => %{"structuredContent" => %{"assignment" => assignment}}},
         %Session{} = session
       )
       when name in @session_claim_tools and is_map(assignment) do
    if assignment_matches_session?(assignment, session), do: name
  end

  defp explicit_claim_tool_name(_payload, _response, %Session{}), do: nil

  defp successful_claim_tool_name(
         %{"method" => "tools/call", "params" => %{"name" => name}},
         %{"result" => %{"structuredContent" => %{"assignment" => assignment}}}
       )
       when name in @session_claim_tools and is_map(assignment),
       do: name

  defp successful_claim_tool_name(_payload, _response), do: nil

  defp notification_claim_tool_name(candidates, %Session{} = session) do
    Enum.reduce(candidates, nil, fn {payload, response}, selected ->
      notification_claim_tool_name(payload, response, session) || selected
    end)
  end

  defp notification_claim_tool_name(
         %{"method" => "tools/call", "params" => %{"name" => name, "arguments" => arguments}},
         nil,
         %Session{} = session
       )
       when name in @local_claim_tools and is_map(arguments) do
    if local_claim_payload_matches_session?(name, arguments, session), do: name
  end

  defp notification_claim_tool_name(_payload, _response, %Session{}), do: nil

  defp claim_payload_count(candidates) do
    Enum.count(candidates, fn {payload, _response} -> claim_payload?(payload) end)
  end

  defp claim_payload?(%{"method" => "tools/call", "params" => %{"name" => name}}) when name in @session_claim_tools, do: true
  defp claim_payload?(_payload), do: false

  defp assignment_matches_session?(assignment, %Session{} = session) when is_map(assignment) do
    public_assignment = Session.public_assignment(session)

    Enum.all?(["grant_id", "work_package_id", "phase_id", "grant_role", "claimed_by"], fn key ->
      Map.get(assignment, key) == Map.get(public_assignment, key)
    end)
  end

  defp local_claim_payload_matches_session?(
         "claim_local_assignment",
         %{"work_package_id" => work_package_id, "claimed_by" => claimed_by},
         %Session{assignment: assignment}
       ) do
    assignment.work_package_id == work_package_id and
      assignment.grant_role == "worker" and
      assignment.claimed_by == claimed_by
  end

  defp local_claim_payload_matches_session?(
         "claim_local_architect_assignment",
         %{"architect_anchor_work_package_id" => work_package_id, "claimed_by" => claimed_by} = arguments,
         %Session{assignment: assignment}
       ) do
    phase_id = Map.get(arguments, "phase_id")

    assignment.work_package_id == work_package_id and
      assignment.grant_role == "architect" and
      assignment.claimed_by == claimed_by and
      (not is_binary(phase_id) or assignment.phase_id == phase_id)
  end

  defp local_claim_payload_matches_session?(_tool_name, _arguments, %Session{}), do: false

  defp response_for_payload(%{"id" => id}, responses) when is_list(responses) do
    Enum.find(responses, :missing, &(Map.get(&1, "id") == id))
  end

  defp response_for_payload(%{"id" => id}, %{"id" => id} = response), do: response
  defp response_for_payload(%{"id" => _id}, _response), do: :missing
  defp response_for_payload(_notification, _response), do: nil

  defp normalize_datetimes(attrs) do
    Map.new(attrs, fn
      {key, %DateTime{} = value} -> {key, DateTime.truncate(value, :microsecond)}
      pair -> pair
    end)
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
