defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository, as: AccessGrantRepository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service, as: AccessGrantService
  alias SymphonyElixir.SymphonyPlusPlus.AgentFormat.ArchitectContext
  alias SymphonyElixir.SymphonyPlusPlus.BaseBranch
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Phase
  alias SymphonyElixir.SymphonyPlusPlus.Phases.Repository, as: PhaseRepository
  alias SymphonyElixir.SymphonyPlusPlus.Repo, as: SymppRepo
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.{ArchitectHandoffClaimLease, ScopeConstraints, WorkRequest}
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository, as: WorkRequestRepository

  @eligible_statuses [
    "ready_for_clarification",
    "clarifying",
    "human_info_needed",
    "ready_for_slicing",
    "sliced"
  ]
  @architect_capabilities [
    "read:phase",
    "read:work_request",
    "write:work_request",
    "dispatch:work_request",
    "read:child_progress",
    "read:child_findings",
    "read:guidance_request",
    "write:guidance_request"
  ]
  @phase_id_prefix "phase-wr-architect-"
  @anchor_id_prefix "SYMPP-WR-ARCH-"
  @anchor_kind "delegation"
  @claimed_by "symphony-architect"
  @file_lock_retries 200
  @file_lock_retry_delay_ms 25
  @file_lock_heartbeat_ms 30_000
  @file_lock_heartbeat_stop_timeout_ms 1_000
  @file_lock_stale_seconds 300
  @local_lock_owner :symphony_plus_plus_architect_handoff_lock_owner
  @local_lock_owner_timeout_ms 1_000
  @local_lock_retry_delay_ms 10
  @local_lock_table :symphony_plus_plus_architect_handoff_locks
  @type error ::
          :database_busy
          | :forbidden
          | :handoff_anchor_scope_conflict
          | :invalid_scope
          | :invalid_status
          | :local_architect_claim_unavailable
          | :not_found
          | {:migration_failed, term()}
          | {:storage_failed, String.t()}
          | term()

  @spec capabilities() :: [String.t()]
  def capabilities, do: @architect_capabilities

  @spec effective_capabilities([String.t()] | nil) :: [String.t()]
  def effective_capabilities(capabilities) do
    normalized_strings(capabilities)
  end

  @spec phase_id_for_work_request(WorkRequest.t()) :: String.t()
  def phase_id_for_work_request(%WorkRequest{} = work_request), do: phase_id(work_request)

  @spec anchor_id_for_work_request(WorkRequest.t()) :: String.t()
  def anchor_id_for_work_request(%WorkRequest{} = work_request), do: anchor_id(work_request)

  @spec handoff_phase_grant?(module(), AccessGrant.t()) :: {:ok, boolean()} | {:error, term()}
  def handoff_phase_grant?(repo, %AccessGrant{} = grant) when is_atom(repo) do
    handoff_phase? = handoff_phase_id?(grant.phase_id)
    handoff_anchor? = handoff_anchor_id?(grant.work_package_id)

    cond do
      handoff_phase? and handoff_anchor? ->
        verified_handoff_phase_grant?(repo, grant)

      handoff_phase? or handoff_anchor? ->
        {:error, :phase_scope_not_available}

      true ->
        {:ok, false}
    end
  end

  @spec claimed_by() :: String.t()
  def claimed_by, do: @claimed_by

  @spec eligible_status?(String.t() | nil) :: boolean()
  def eligible_status?(status) when is_binary(status), do: status in @eligible_statuses
  def eligible_status?(_status), do: false

  @spec eligible_scope?(WorkRequest.t() | map() | term()) :: boolean()
  def eligible_scope?(work_request) when is_map(work_request) do
    require_frozen_scope(work_request) == :ok and require_valid_file_scope(work_request) == :ok
  end

  def eligible_scope?(_work_request), do: false

  @spec create_or_replay(module(), String.t(), keyword()) :: {:ok, map()} | {:error, error()}
  def create_or_replay(repo, work_request_id, opts \\ [])
      when is_atom(repo) and is_binary(work_request_id) and is_list(opts) do
    with :ok <- require_local_operator(opts) do
      with_handoff_lock(repo, work_request_id, fn -> create_or_replay_locked(repo, work_request_id, opts) end)
    end
  end

  @spec existing_display(module(), String.t(), keyword()) :: {:ok, map() | nil} | {:error, error()}
  def existing_display(repo, work_request_id, opts \\ [])
      when is_atom(repo) and is_binary(work_request_id) and is_list(opts) do
    with :ok <- require_local_operator(opts) do
      repo
      |> read_existing_display(work_request_id, opts)
      |> normalize_existing_display_result()
    end
  end

  defp create_or_replay_locked(repo, work_request_id, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    handoff_opts = handoff_opts(opts)

    with {:ok, work_request} <- WorkRequestRepository.get(repo, work_request_id),
         :ok <- require_eligible_status(work_request),
         :ok <- require_frozen_scope(work_request),
         :ok <- require_valid_file_scope(work_request),
         {:ok, phase} <- get_or_create_phase(repo, work_request),
         {:ok, anchor} <- get_or_create_anchor(repo, work_request, phase),
         {:ok, grants} <- AccessGrantRepository.list_for_work_package(repo, anchor.id) do
      replay_or_create_handoff(repo, work_request, phase, anchor, grants, handoff_opts, now)
    end
  end

  defp read_existing_display(repo, work_request_id, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    handoff_opts = handoff_opts(opts)

    with {:ok, work_request} <- WorkRequestRepository.get(repo, work_request_id),
         :ok <- require_eligible_status(work_request),
         :ok <- require_frozen_scope(work_request),
         :ok <- require_valid_file_scope(work_request),
         {:ok, phase} <- PhaseRepository.get(repo, phase_id(work_request)),
         {:ok, anchor} <- WorkPackageRepository.get(repo, anchor_id(work_request)),
         {:ok, anchor} <- validate_anchor(anchor, work_request, phase),
         {:ok, grants} <- AccessGrantRepository.list_for_work_package(repo, anchor.id) do
      existing_display_for_latest_handoff(repo, work_request, phase, anchor, grants, handoff_opts, now)
    end
  end

  defp normalize_existing_display_result({:ok, handoff}), do: {:ok, handoff}
  defp normalize_existing_display_result({:error, {:storage_failed, _reason} = reason}), do: {:error, reason}
  defp normalize_existing_display_result({:error, _reason}), do: {:ok, nil}

  @spec error_message(term()) :: String.t()
  def error_message(:forbidden), do: "architect handoff is only available in local operator mode"
  def error_message(:handoff_anchor_scope_conflict), do: "existing architect handoff anchor does not match the WorkRequest scope"
  def error_message(:invalid_scope), do: "WorkRequest must have a repo and base branch before architect handoff"
  def error_message(:invalid_status), do: "WorkRequest is not ready for architect handoff"
  def error_message(:local_architect_claim_unavailable), do: "architect handoff requires a local file-backed ledger claim path"
  def error_message(:not_found), do: "WorkRequest was not found"
  def error_message(:database_busy), do: "the Symphony++ ledger is busy"
  def error_message({:storage_failed, _reason}), do: "the Symphony++ ledger could not store the architect handoff"

  def error_message({:handoff_setup_rollback_failed, _reason, _failures}),
    do: "architect handoff setup failed and local grant/secret cleanup needs attention"

  def error_message(%Ecto.Changeset{}), do: "architect handoff data did not pass validation"

  def error_message(reason) do
    "architect handoff failed: #{inspect(reason)}"
  end

  defp require_local_operator(opts) do
    if Keyword.get(opts, :local_operator?, false) == true do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp handoff_phase_id?(phase_id) when is_binary(phase_id), do: String.starts_with?(phase_id, @phase_id_prefix)
  defp handoff_phase_id?(_phase_id), do: false

  defp handoff_anchor_id?(anchor_id) when is_binary(anchor_id), do: String.starts_with?(anchor_id, @anchor_id_prefix)
  defp handoff_anchor_id?(_anchor_id), do: false

  defp verified_handoff_phase_grant?(repo, %AccessGrant{} = grant) do
    with {:ok, anchor} <- handoff_anchor_work_package(repo, grant),
         [] <- handoff_anchor_scope_missing_evidence(anchor, grant),
         {:ok, work_request} <- handoff_grant_work_request(repo, grant, anchor) do
      handoff_work_request_grant_state(work_request, anchor)
    else
      missing when is_list(missing) -> {:error, phase_scope_not_available(missing)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handoff_anchor_work_package(repo, %AccessGrant{} = grant) do
    case WorkPackageRepository.get(repo, grant.work_package_id) do
      {:ok, %WorkPackage{} = anchor} -> {:ok, anchor}
      {:error, :not_found} -> {:error, phase_scope_not_available([:architect_anchor_work_package])}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handoff_anchor_scope_missing_evidence(%WorkPackage{} = anchor, %AccessGrant{} = grant) do
    [
      if(anchor.id != grant.work_package_id, do: :architect_anchor_work_package_id),
      if(anchor.phase_id != grant.phase_id, do: :phase_id),
      if(anchor.kind != @anchor_kind, do: :architect_anchor_kind),
      if(not present_string?(anchor.repo), do: :architect_anchor_repo),
      if(not present_string?(anchor.base_branch), do: :architect_anchor_base_branch)
    ]
    |> Kernel.++(handoff_grant_repo_scope_missing_evidence(anchor, grant))
    |> Enum.reject(&is_nil/1)
  end

  defp handoff_grant_repo_scope_missing_evidence(%WorkPackage{} = anchor, %AccessGrant{} = grant) do
    repo_scope? = present_string?(grant.scope_repo)
    base_branch_scope? = present_string?(grant.scope_base_branch)

    cond do
      repo_scope? and base_branch_scope? ->
        [
          if(not repo_scope_match?(anchor.repo, grant.scope_repo), do: :grant_scope_repo),
          if(not branch_scope_match?(anchor.base_branch, grant.scope_base_branch), do: :grant_scope_base_branch)
        ]

      repo_scope? ->
        [:grant_scope_base_branch]

      base_branch_scope? ->
        [:grant_scope_repo]

      true ->
        []
    end
  end

  defp handoff_grant_work_request(repo, %AccessGrant{} = grant, %WorkPackage{} = anchor) do
    with {:ok, work_request_ids} <- work_request_scope_ids(repo, grant) do
      case Enum.uniq(work_request_ids) do
        [work_request_id] ->
          handoff_scoped_work_request(repo, work_request_id, anchor)

        [] ->
          single_handoff_anchor_work_request(repo, anchor)

        _work_request_ids ->
          {:error, :ambiguous_phase_scope}
      end
    end
  end

  defp handoff_scoped_work_request(repo, work_request_id, %WorkPackage{} = anchor) do
    case WorkRequestRepository.get(repo, work_request_id) do
      {:ok, %WorkRequest{} = work_request} ->
        if work_request_scope_matches_handoff_anchor?(work_request, anchor) do
          {:ok, work_request}
        else
          single_handoff_anchor_work_request(repo, anchor)
        end

      {:error, :not_found} ->
        single_handoff_anchor_work_request(repo, anchor)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handoff_work_request_grant_state(%WorkRequest{} = work_request, %WorkPackage{} = anchor) do
    case handoff_work_request_terminal_state(work_request) do
      nil ->
        case handoff_work_request_missing_evidence(work_request, anchor) do
          [] -> {:ok, true}
          missing_evidence -> {:error, phase_scope_not_available(missing_evidence)}
        end

      terminal_state ->
        {:error, {:work_request_terminal, terminal_state}}
    end
  end

  defp handoff_work_request_terminal_state(%WorkRequest{archived_at: %DateTime{}}), do: :archived

  defp handoff_work_request_terminal_state(%WorkRequest{
         completed_at: %DateTime{},
         completion_source: "operator"
       }),
       do: :completed

  defp handoff_work_request_terminal_state(%WorkRequest{}), do: nil

  defp handoff_work_request_missing_evidence(%WorkRequest{} = work_request, %WorkPackage{} = anchor) do
    status_evidence =
      if handoff_work_request_status_available?(work_request), do: nil, else: :work_request_status

    [status_evidence | handoff_work_request_scope_missing_evidence(work_request, anchor)]
    |> Enum.reject(&is_nil/1)
  end

  defp handoff_work_request_status_available?(%WorkRequest{} = work_request), do: eligible_status?(work_request.status)

  defp handoff_work_request_scope_missing_evidence(%WorkRequest{} = work_request, %WorkPackage{} = anchor) do
    [
      if(phase_id(work_request) != anchor.phase_id, do: :phase_id),
      if(anchor_id(work_request) != anchor.id, do: :architect_anchor_work_package_id),
      if(not repo_scope_match?(work_request.repo, anchor.repo), do: :work_request_repo),
      if(not branch_scope_match?(work_request.base_branch, anchor.base_branch), do: :work_request_base_branch),
      if(not handoff_work_request_file_scope_matches?(work_request, anchor), do: :work_request_allowed_file_globs)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp handoff_work_request_file_scope_matches?(%WorkRequest{} = work_request, %WorkPackage{} = anchor) do
    case work_request_allowed_file_globs(work_request) do
      {:ok, allowed_file_globs} -> normalized_strings(anchor.allowed_file_globs || []) == allowed_file_globs
      {:error, _reason} -> false
    end
  end

  defp work_request_scope_matches_handoff_anchor?(%WorkRequest{} = work_request, %WorkPackage{} = anchor) do
    handoff_work_request_scope_missing_evidence(work_request, anchor) == []
  end

  defp single_handoff_anchor_work_request(repo, %WorkPackage{} = anchor) do
    with {:ok, work_requests} <- handoff_anchor_work_requests(repo, anchor) do
      case Enum.filter(work_requests, &work_request_scope_matches_handoff_anchor?(&1, anchor)) do
        [work_request] -> {:ok, work_request}
        [] -> {:error, phase_scope_not_available([:work_request_scope])}
        _work_requests -> {:error, :ambiguous_phase_scope}
      end
    end
  end

  defp handoff_anchor_work_requests(repo, %WorkPackage{} = anchor) do
    Enum.reduce_while(BaseBranch.equivalent_refs(anchor.base_branch), {:ok, []}, fn base_branch, {:ok, work_requests} ->
      case WorkRequestRepository.list(repo, %{"base_branch" => base_branch, "include_archived" => true}) do
        {:ok, matches} -> {:cont, {:ok, matches ++ work_requests}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, work_requests} -> {:ok, Enum.uniq_by(work_requests, & &1.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp phase_scope_not_available(missing_evidence) do
    {:phase_scope_not_available, missing_evidence |> List.wrap() |> Enum.uniq()}
  end

  defp with_handoff_lock(repo, work_request_id, fun) when is_function(fun, 0) do
    lock_id = {{__MODULE__, repo}, work_request_id}

    case with_handoff_file_lock(repo, work_request_id, fn -> handoff_lock_transaction(lock_id, fun) end) do
      :aborted -> {:error, :database_busy}
      result -> result
    end
  end

  defp with_handoff_file_lock(repo, work_request_id, fun, retries \\ @file_lock_retries)

  defp with_handoff_file_lock(_repo, _work_request_id, _fun, 0), do: :aborted

  defp with_handoff_file_lock(repo, work_request_id, fun, retries) do
    lock_path = handoff_file_lock_path(repo, work_request_id)

    case File.mkdir_p(Path.dirname(lock_path)) do
      :ok -> acquire_handoff_file_lock(lock_path, repo, work_request_id, fun, retries)
      {:error, _reason} -> :aborted
    end
  end

  defp acquire_handoff_file_lock(lock_path, repo, work_request_id, fun, retries) do
    case File.open(lock_path, [:write, :exclusive]) do
      {:ok, io_device} ->
        heartbeat = start_handoff_file_lock_heartbeat(lock_path)

        try do
          IO.write(io_device, "#{node()} #{inspect(self())}\n")
          fun.()
        after
          stop_handoff_file_lock_heartbeat(heartbeat)
          File.close(io_device)
          File.rm(lock_path)
        end

      {:error, :eexist} ->
        maybe_remove_stale_handoff_file_lock(lock_path)
        Process.sleep(@file_lock_retry_delay_ms)
        with_handoff_file_lock(repo, work_request_id, fun, retries - 1)

      {:error, _reason} ->
        :aborted
    end
  end

  defp handoff_file_lock_path(repo, work_request_id) do
    database_key =
      repo
      |> repo_database_path()
      |> SymppRepo.database_key()

    lock_name =
      {repo, database_key, work_request_id}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    Path.join([System.tmp_dir() || ".", "symphony_plus_plus_architect_handoff_locks", lock_name <> ".lock"])
  end

  defp repo_database_path(repo) do
    if function_exported?(repo, :database_path, 0), do: repo.database_path(), else: repo
  end

  defp maybe_remove_stale_handoff_file_lock(lock_path) do
    case File.stat(lock_path, time: :posix) do
      {:ok, %{mtime: mtime}} when is_integer(mtime) ->
        if System.os_time(:second) - mtime > @file_lock_stale_seconds do
          File.rm(lock_path)
        else
          :ok
        end

      _missing_or_unreadable ->
        :ok
    end
  end

  defp start_handoff_file_lock_heartbeat(lock_path) do
    owner = self()
    ref = make_ref()
    pid = spawn(fn -> handoff_file_lock_heartbeat(lock_path, ref, owner) end)
    {pid, ref}
  end

  defp stop_handoff_file_lock_heartbeat({pid, ref}) when is_pid(pid) do
    monitor = Process.monitor(pid)
    send(pid, {:stop, ref, self()})

    receive do
      {:handoff_file_lock_heartbeat_stopped, ^ref} ->
        Process.demonitor(monitor, [:flush])
        :ok

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :ok
    after
      @file_lock_heartbeat_stop_timeout_ms ->
        Process.exit(pid, :kill)
        wait_for_handoff_file_lock_heartbeat_down(monitor, pid)
    end
  end

  defp handoff_file_lock_heartbeat(lock_path, ref, owner) do
    owner_monitor = Process.monitor(owner)
    handoff_file_lock_heartbeat_loop(lock_path, ref, owner_monitor)
  end

  defp handoff_file_lock_heartbeat_loop(lock_path, ref, owner_monitor) do
    receive do
      {:stop, ^ref, caller} ->
        Process.demonitor(owner_monitor, [:flush])
        send(caller, {:handoff_file_lock_heartbeat_stopped, ref})
        :ok

      {:DOWN, ^owner_monitor, :process, _owner, _reason} ->
        :ok
    after
      @file_lock_heartbeat_ms ->
        File.touch(lock_path)
        handoff_file_lock_heartbeat_loop(lock_path, ref, owner_monitor)
    end
  end

  defp wait_for_handoff_file_lock_heartbeat_down(monitor, pid) do
    receive do
      {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
    after
      @file_lock_heartbeat_stop_timeout_ms -> :ok
    end
  end

  defp handoff_lock_transaction(lock_id, fun) do
    if Node.alive?() do
      :global.trans(lock_id, fun, connected_nodes(), :infinity)
    else
      local_transaction(lock_id, fun)
    end
  end

  defp connected_nodes, do: Enum.uniq([node() | Node.list()])

  defp local_transaction(lock_id, fun) when is_function(fun, 0) do
    case acquire_local_lock(lock_id) do
      :ok ->
        try do
          fun.()
        after
          release_local_lock(lock_id)
        end

      :busy ->
        Process.sleep(@local_lock_retry_delay_ms)
        local_transaction(lock_id, fun)

      :unavailable ->
        :aborted
    end
  end

  defp acquire_local_lock(lock_id) do
    case ensure_local_lock_table() do
      :ok ->
        try do
          if :ets.insert_new(@local_lock_table, {lock_id, self()}) do
            :ok
          else
            acquire_existing_local_lock(lock_id)
          end
        rescue
          ArgumentError -> :unavailable
        end

      _not_ready ->
        :unavailable
    end
  end

  defp acquire_existing_local_lock(lock_id) do
    case :ets.lookup(@local_lock_table, lock_id) do
      [{^lock_id, pid}] when is_pid(pid) ->
        if Process.alive?(pid) do
          :busy
        else
          :ets.delete(@local_lock_table, lock_id)
          acquire_local_lock(lock_id)
        end

      _entry ->
        :busy
    end
  end

  defp release_local_lock(lock_id) do
    :ets.delete(@local_lock_table, lock_id)
  rescue
    ArgumentError -> :ok
  end

  defp ensure_local_lock_table do
    case :ets.whereis(@local_lock_table) do
      :undefined ->
        @local_lock_owner
        |> ensure_local_lock_owner()
        |> request_local_lock_table()

      _table ->
        :ok
    end
  end

  defp ensure_local_lock_owner(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        pid

      nil ->
        parent = self()
        pid = spawn(fn -> local_lock_owner(parent, name) end)

        receive do
          {:local_lock_owner_ready, ^pid} -> pid
          {:local_lock_owner_exists, ^pid, owner_pid} -> owner_pid || ensure_local_lock_owner(name)
        after
          @local_lock_owner_timeout_ms ->
            case Process.whereis(name) do
              owner_pid when is_pid(owner_pid) -> owner_pid
              nil -> ensure_local_lock_owner(name)
            end
        end
    end
  end

  defp local_lock_owner(parent, name) do
    Process.register(self(), name)
    ensure_local_lock_table_owned()
    send(parent, {:local_lock_owner_ready, self()})
    local_lock_owner_loop()
  rescue
    ArgumentError ->
      send(parent, {:local_lock_owner_exists, self(), Process.whereis(name)})
  end

  defp local_lock_owner_loop do
    receive do
      {:ensure_local_lock_table, caller, ref} ->
        ensure_local_lock_table_owned()
        send(caller, {:local_lock_table_ready, ref})
        local_lock_owner_loop()

      _message ->
        local_lock_owner_loop()
    end
  end

  defp request_local_lock_table(owner_pid) when is_pid(owner_pid) do
    ref = make_ref()
    send(owner_pid, {:ensure_local_lock_table, self(), ref})

    receive do
      {:local_lock_table_ready, ^ref} -> :ok
    after
      @local_lock_owner_timeout_ms -> :error
    end
  end

  defp ensure_local_lock_table_owned do
    case :ets.whereis(@local_lock_table) do
      :undefined -> :ets.new(@local_lock_table, [:named_table, :public, :set])
      _table -> :ok
    end
  end

  defp require_eligible_status(%WorkRequest{status: status}) do
    if eligible_status?(status), do: :ok, else: {:error, :invalid_status}
  end

  defp require_frozen_scope(work_request) when is_map(work_request) do
    repo = work_request_value(work_request, :repo)
    base_branch = work_request_value(work_request, :base_branch)

    if present_string?(repo) and present_string?(base_branch) do
      :ok
    else
      {:error, :invalid_scope}
    end
  end

  defp require_valid_file_scope(work_request) when is_map(work_request) do
    with {:ok, _allowed_file_globs} <- work_request_allowed_file_globs(work_request) do
      :ok
    end
  end

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp get_or_create_phase(repo, %WorkRequest{} = work_request) do
    phase_id = phase_id(work_request)

    case PhaseRepository.get(repo, phase_id) do
      {:ok, %Phase{} = phase} ->
        {:ok, phase}

      {:error, :not_found} ->
        create_phase(repo, work_request, phase_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_phase(repo, %WorkRequest{} = work_request, phase_id) do
    case PhaseRepository.create(repo, %{
           id: phase_id,
           title: "Architect handoff for #{work_request.id}",
           description: "Local operator architect handoff for WorkRequest #{work_request.id}; scoped to #{work_request.repo} / #{work_request.base_branch}."
         }) do
      {:ok, %Phase{} = phase} -> {:ok, phase}
      {:error, :id_already_exists} -> PhaseRepository.get(repo, phase_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_or_create_anchor(repo, %WorkRequest{} = work_request, %Phase{} = phase) do
    anchor_id = anchor_id(work_request)

    case WorkPackageRepository.get(repo, anchor_id) do
      {:ok, %WorkPackage{} = anchor} ->
        validate_anchor(anchor, work_request, phase)

      {:error, :not_found} ->
        create_anchor(repo, work_request, phase, anchor_id)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_anchor(repo, %WorkRequest{} = work_request, %Phase{} = phase, anchor_id) do
    with {:ok, allowed_file_globs} <- work_request_allowed_file_globs(work_request) do
      create_anchor(repo, work_request, phase, anchor_id, allowed_file_globs)
    end
  end

  defp create_anchor(repo, %WorkRequest{} = work_request, %Phase{} = phase, anchor_id, allowed_file_globs) do
    attrs = %{
      id: anchor_id,
      kind: @anchor_kind,
      title: "Architect handoff: #{work_request.title}",
      repo: work_request.repo,
      base_branch: work_request.base_branch,
      branch_pattern: "agent/#{String.downcase(anchor_id)}/architect-handoff",
      product_description: work_request.human_description,
      engineering_scope:
        "Architect anchor for WorkRequest #{work_request.id}. Launch with opt-in Symphony++ MCP loaded, then use the symphony-plus-plus-mcp:symphony-architect skill and WorkRequest MCP tools before slicing.",
      allowed_file_globs: allowed_file_globs,
      acceptance_criteria: [
        "Architect agent can read and update the scoped WorkRequest.",
        "Architect agent can answer or escalate scoped guidance requests.",
        "WorkPackage dispatch remains explicit and scoped."
      ],
      status: "planning",
      phase_id: phase.id,
      owner_id: @claimed_by
    }

    case WorkPackageRepository.create(repo, attrs) do
      {:ok, %WorkPackage{} = anchor} ->
        {:ok, anchor}

      {:error, :id_already_exists} ->
        with {:ok, %WorkPackage{} = anchor} <- WorkPackageRepository.get(repo, anchor_id) do
          validate_anchor(anchor, work_request, phase)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_anchor(%WorkPackage{} = anchor, %WorkRequest{} = work_request, %Phase{} = phase) do
    with {:ok, allowed_file_globs} <- work_request_allowed_file_globs(work_request) do
      valid_anchor? =
        anchor.phase_id == phase.id and
          anchor.kind == @anchor_kind and
          repo_scope_match?(anchor.repo, work_request.repo) and
          branch_scope_match?(anchor.base_branch, work_request.base_branch) and
          normalized_strings(anchor.allowed_file_globs || []) == allowed_file_globs

      if valid_anchor?, do: {:ok, anchor}, else: {:error, :handoff_anchor_scope_conflict}
    end
  end

  defp work_request_allowed_file_globs(%WorkRequest{constraints: constraints}) when is_map(constraints) do
    work_request_allowed_file_globs_from_constraints(constraints)
  end

  defp work_request_allowed_file_globs(%WorkRequest{}), do: {:ok, []}

  defp work_request_allowed_file_globs(work_request) when is_map(work_request) do
    case work_request_value(work_request, :constraints) do
      constraints when is_map(constraints) -> work_request_allowed_file_globs_from_constraints(constraints)
      nil -> {:ok, []}
      _constraints -> {:error, :invalid_scope}
    end
  end

  defp work_request_allowed_file_globs_from_constraints(constraints) when is_map(constraints) do
    case work_request_constraint_value(constraints, :allowed_paths) do
      :missing -> validate_allowed_file_globs(constraints, [])
      values when is_list(values) -> normalize_allowed_file_globs(constraints, values)
      _values -> {:error, :invalid_scope}
    end
  end

  defp work_request_constraint_value(constraints, key) when is_map(constraints) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(constraints, string_key) -> Map.fetch!(constraints, string_key)
      Map.has_key?(constraints, key) -> Map.fetch!(constraints, key)
      true -> :missing
    end
  end

  defp normalize_allowed_file_globs(constraints, values) do
    case normalized_nonblank_strings(values) do
      {:ok, allowed_paths} ->
        allowed_file_globs = allowed_paths_to_file_globs(allowed_paths)
        validate_allowed_file_globs(constraints, allowed_file_globs)

      {:error, :invalid_scope} ->
        {:error, :invalid_scope}
    end
  end

  defp allowed_paths_to_file_globs(allowed_paths) do
    allowed_paths
    |> Enum.flat_map(&allowed_path_to_file_globs/1)
    |> normalized_strings()
  end

  defp allowed_path_to_file_globs(allowed_path) do
    if glob_path?(allowed_path) do
      [allowed_path]
    else
      [allowed_path, "#{allowed_path}/**"]
    end
  end

  defp glob_path?(path), do: String.contains?(path, ["*", "?", "["])

  defp validate_allowed_file_globs(constraints, allowed_file_globs) do
    case ScopeConstraints.validate_allowed_file_globs(constraints, allowed_file_globs) do
      :ok -> {:ok, allowed_file_globs}
      {:error, _errors} -> {:error, :invalid_scope}
    end
  end

  defp normalized_nonblank_strings(values) when is_list(values) do
    if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
      {:ok, normalized_strings(values)}
    else
      {:error, :invalid_scope}
    end
  end

  defp normalized_nonblank_strings(_values), do: {:error, :invalid_scope}

  defp normalized_strings(values) when is_list(values) do
    values
    |> Enum.map(&String.trim/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalized_strings(_values), do: []

  defp work_request_value(%WorkRequest{} = work_request, key), do: Map.get(work_request, key)

  defp work_request_value(work_request, key) when is_map(work_request) and is_atom(key) do
    Map.get(work_request, key) || Map.get(work_request, Atom.to_string(key))
  end

  defp replay_active_handoff(
         repo,
         %WorkRequest{} = work_request,
         %Phase{} = phase,
         %WorkPackage{} = anchor,
         grants,
         handoff_opts,
         now
       ) do
    active_handoff_grants =
      grants
      |> Enum.filter(&active_unclaimed_handoff_grant?(&1, phase, anchor, now))
      |> Enum.reverse()

    case split_replayable_handoff_grants(repo, active_handoff_grants, work_request, phase, anchor, now) do
      {:ok, replayable_grants, stale_grants} ->
        replay_latest_active_handoff(repo, work_request, phase, anchor, replayable_grants, handoff_opts, stale_grants)

      {:error, _reason} = error ->
        error
    end
  end

  defp existing_display_for_latest_handoff(
         repo,
         %WorkRequest{} = work_request,
         %Phase{} = phase,
         %WorkPackage{} = anchor,
         grants,
         handoff_opts,
         now
       ) do
    active_handoff_grants = latest_active_unclaimed_handoff_grants(grants, phase, anchor, now)

    case split_replayable_handoff_grants(repo, active_handoff_grants, work_request, phase, anchor, now) do
      {:ok, replayable_grants, _stale_grants} ->
        existing_display_for_replayable_handoffs(replayable_grants, work_request, phase, anchor, handoff_opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp existing_display_for_replayable_handoffs([], %WorkRequest{}, %Phase{}, %WorkPackage{}, _handoff_opts), do: {:ok, nil}

  defp existing_display_for_replayable_handoffs([%AccessGrant{} = grant | _older_grants], %WorkRequest{} = work_request, %Phase{} = phase, %WorkPackage{} = anchor, handoff_opts) do
    with :ok <- require_local_architect_claim_available(handoff_opts) do
      {:ok, result(:replayed, work_request, phase, anchor, grant, handoff_opts)}
    end
  end

  defp replay_or_create_handoff(repo, %WorkRequest{} = work_request, %Phase{} = phase, %WorkPackage{} = anchor, grants, handoff_opts, now) do
    case replay_active_handoff(repo, work_request, phase, anchor, grants, handoff_opts, now) do
      {:ok, handoff} ->
        {:ok, handoff}

      {:error, _reason} = error ->
        error

      :not_found ->
        with :ok <- ArchitectHandoffClaimLease.require_no_fresh(repo, anchor.id, now) do
          create_new_handoff(repo, work_request, phase, anchor, handoff_opts, grants)
        end
    end
  end

  defp replay_latest_active_handoff(repo, %WorkRequest{} = work_request, %Phase{} = phase, %WorkPackage{} = anchor, [%AccessGrant{} = grant | older_grants], handoff_opts, stale_grants) do
    grants_to_retire = stale_grants ++ older_grants

    with :ok <- require_local_architect_claim_available(handoff_opts),
         :ok <- retire_active_handoffs(repo, anchor, grants_to_retire, handoff_opts) do
      {:ok, result(:replayed, work_request, phase, anchor, grant, handoff_opts)}
    end
  end

  defp replay_latest_active_handoff(repo, _work_request, _phase, %WorkPackage{} = anchor, [], handoff_opts, stale_grants) do
    with :ok <- retire_active_handoffs(repo, anchor, stale_grants, handoff_opts) do
      :not_found
    end
  end

  defp retire_active_handoffs(repo, %WorkPackage{} = anchor, grants, handoff_opts) do
    Enum.reduce_while(grants, :ok, fn grant, :ok ->
      case retire_active_handoff(repo, anchor, grant, handoff_opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp retire_active_handoff(repo, %WorkPackage{}, %AccessGrant{} = grant, handoff_opts) do
    revoke_architect_grant(repo, grant, handoff_opts)
  end

  defp create_new_handoff(repo, %WorkRequest{} = work_request, %Phase{} = phase, %WorkPackage{} = anchor, handoff_opts, grants) do
    status = if architect_handoff_grants?(grants, phase, anchor), do: :renewed, else: :created

    with :ok <- require_local_architect_claim_available(handoff_opts),
         {:ok, minted} <-
           AccessGrantService.mint_architect_grant(repo, phase.id,
             work_package_id: anchor.id,
             work_request_id: work_request.id,
             capabilities: @architect_capabilities
           ) do
      {:ok, result(status, work_request, phase, anchor, minted.grant, handoff_opts)}
    end
  end

  defp revoke_architect_grant(repo, %AccessGrant{} = grant, handoff_opts) do
    case Keyword.get(handoff_opts, :revoke_grant) do
      nil -> AccessGrantService.revoke(repo, grant.id)
      revoke_fun when is_function(revoke_fun, 3) -> revoke_fun.(repo, grant, handoff_opts)
      _invalid -> {:error, :invalid_architect_grant_revoke_fun}
    end
    |> case do
      :ok -> :ok
      {:ok, _grant} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_architect_grant_revoke_result, other}}
    end
  end

  defp architect_handoff_grants?(grants, %Phase{} = phase, %WorkPackage{} = anchor) do
    Enum.any?(grants, &architect_handoff_grant?(&1, phase, anchor))
  end

  defp latest_active_unclaimed_handoff_grants(grants, %Phase{} = phase, %WorkPackage{} = anchor, now) do
    grants
    |> Enum.filter(&active_unclaimed_handoff_grant?(&1, phase, anchor, now))
    |> Enum.sort_by(&architect_handoff_grant_order_key/1, :desc)
  end

  defp architect_handoff_grant?(
         %AccessGrant{grant_role: "architect", phase_id: phase_id, work_package_id: work_package_id},
         %Phase{} = phase,
         %WorkPackage{} = anchor
       ) do
    phase_id == phase.id and work_package_id == anchor.id
  end

  defp architect_handoff_grant?(_grant, _phase, _anchor), do: false

  defp architect_handoff_grant_order_key(%AccessGrant{inserted_at: %DateTime{} = inserted_at, id: id}) do
    {DateTime.to_unix(inserted_at, :microsecond), id || ""}
  end

  defp architect_handoff_grant_order_key(%AccessGrant{id: id}), do: {-1, id || ""}

  defp active_unclaimed_handoff_grant?(%AccessGrant{} = grant, %Phase{} = phase, %WorkPackage{} = anchor, now) do
    grant.grant_role == "architect" and
      grant.work_package_id == anchor.id and
      grant.phase_id == phase.id and
      is_nil(grant.revoked_at) and
      is_nil(grant.claimed_at) and
      live_expires_at?(grant.expires_at, now)
  end

  defp split_replayable_handoff_grants(repo, grants, %WorkRequest{} = work_request, %Phase{} = phase, %WorkPackage{} = anchor, now) do
    Enum.reduce_while(grants, {:ok, [], []}, fn grant, {:ok, replayable_grants, stale_grants} ->
      case matching_handoff_grant(repo, grant, work_request, phase, anchor, now) do
        {:ok, true} -> {:cont, {:ok, [grant | replayable_grants], stale_grants}}
        {:ok, false} -> {:cont, {:ok, replayable_grants, [grant | stale_grants]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, replayable_grants, stale_grants} -> {:ok, Enum.reverse(replayable_grants), Enum.reverse(stale_grants)}
      {:error, _reason} = error -> error
    end
  end

  defp matching_handoff_grant(repo, %AccessGrant{} = grant, %WorkRequest{} = work_request, %Phase{} = phase, %WorkPackage{} = anchor, now) do
    if active_unclaimed_handoff_grant?(grant, phase, anchor, now) and
         repo_scope_match?(grant.scope_repo, work_request.repo) and
         branch_scope_match?(grant.scope_base_branch, work_request.base_branch) and
         required_capabilities?(grant.capabilities) do
      scoped_to_work_request(repo, grant, work_request)
    else
      {:ok, false}
    end
  end

  defp scoped_to_work_request(repo, %AccessGrant{} = grant, %WorkRequest{} = work_request) do
    case work_request_scope_ids(repo, grant) do
      {:ok, scope_ids} ->
        {:ok, work_request.id in scope_ids}

      {:error, _reason} = error ->
        error
    end
  end

  defp repo_scope_match?(expected_repo, actual_repo) when is_binary(expected_repo) and is_binary(actual_repo) do
    RepoIdentity.scope_match?(expected_repo, actual_repo,
      trusted_remotes: repo_scope_trusted_remotes(),
      local_path_remotes?: true
    )
  end

  defp repo_scope_match?(_expected_repo, _actual_repo), do: false

  defp branch_scope_match?(expected_branch, actual_branch)
       when is_binary(expected_branch) and is_binary(actual_branch) do
    BaseBranch.canonicalize(expected_branch) == BaseBranch.canonicalize(actual_branch)
  end

  defp branch_scope_match?(_expected_branch, _actual_branch), do: false

  defp repo_scope_trusted_remotes do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp work_request_scope_ids(repo, %AccessGrant{} = grant) do
    case AccessGrantRepository.list_scopes(repo, grant.id) do
      {:ok, scopes} ->
        scope_ids =
          scopes
          |> Enum.filter(&(&1.scope_type == "work_request"))
          |> Enum.map(& &1.scope_id)

        {:ok, scope_ids}

      {:error, _reason} = error ->
        error
    end
  end

  defp live_expires_at?(%DateTime{} = expires_at, %DateTime{} = now), do: DateTime.compare(expires_at, now) == :gt
  defp live_expires_at?(nil, %DateTime{}), do: true
  defp live_expires_at?(_expires_at, _now), do: false

  defp required_capabilities?(capabilities) when is_list(capabilities) do
    capability_set = MapSet.new(capabilities)
    Enum.all?(@architect_capabilities, &MapSet.member?(capability_set, &1))
  end

  defp required_capabilities?(_capabilities), do: false

  defp result(status, %WorkRequest{} = work_request, %Phase{} = phase, %WorkPackage{} = anchor, %AccessGrant{} = grant, handoff_opts) do
    local_architect_claim = local_architect_claim(work_request, phase, anchor, grant, handoff_opts)

    reference_identifiers =
      prompt_reference_identifiers(work_request, phase, anchor, handoff_opts, local_architect_claim)

    agent_context = ArchitectContext.encode_handoff_reference(reference_identifiers)

    %{
      status: status,
      work_request: %{
        id: work_request.id,
        repo: work_request.repo,
        base_branch: work_request.base_branch,
        status: work_request.status
      },
      phase: %{id: phase.id, title: phase.title, status: phase.status},
      anchor_package: %{
        id: anchor.id,
        repo: anchor.repo,
        base_branch: anchor.base_branch,
        status: anchor.status
      },
      grant: grant_metadata(grant),
      local_architect_claim: local_architect_claim,
      agent_context: agent_context,
      prompt: prompt(local_architect_claim, agent_context)
    }
  end

  defp grant_metadata(%AccessGrant{} = grant) do
    %{
      id: grant.id,
      grant_role: grant.grant_role,
      capabilities: grant.capabilities || [],
      phase_id: grant.phase_id,
      work_package_id: grant.work_package_id,
      scope_repo: grant.scope_repo,
      scope_base_branch: grant.scope_base_branch,
      expires_at: timestamp(grant.expires_at),
      claimed_at: timestamp(grant.claimed_at),
      claimed_by: grant.claimed_by,
      revoked_at: timestamp(grant.revoked_at),
      secret_in_response: false
    }
  end

  defp local_architect_claim(%WorkRequest{} = work_request, %Phase{}, %WorkPackage{}, %AccessGrant{}, handoff_opts) do
    if local_architect_claim_available?(handoff_opts) do
      claimed_by = Keyword.get(handoff_opts, :claimed_by, @claimed_by)

      %{
        "tool" => "claim_local_architect_assignment",
        "arguments" => %{
          "work_request_id" => work_request.id,
          "claimed_by" => claimed_by
        },
        "required_runtime_arguments" => [],
        "secret_in_response" => false
      }
    end
  end

  defp local_architect_claim_available?(handoff_opts) do
    Keyword.get(handoff_opts, :local_architect_claim?, false) == true and file_backed_handoff_database?(handoff_database(handoff_opts))
  end

  defp require_local_architect_claim_available(handoff_opts) do
    if local_architect_claim_available?(handoff_opts), do: :ok, else: {:error, :local_architect_claim_unavailable}
  end

  defp file_backed_handoff_database?(database) when is_binary(database) do
    database = String.trim(database)

    database != "" and
      not SymppRepo.memory_database?(database) and
      not remote_handoff_database?(database)
  end

  defp file_backed_handoff_database?(_database), do: false

  defp remote_handoff_database?(database) do
    remote_handoff_database_uri?(database) or remote_handoff_database_descriptor?(database)
  end

  defp remote_handoff_database_uri?(database) do
    case URI.parse(database) do
      %URI{scheme: scheme} when is_binary(scheme) and scheme != "" ->
        String.downcase(scheme) != "file" and not windows_drive_path?(database)

      _uri ->
        false
    end
  end

  defp remote_handoff_database_descriptor?(database) do
    Regex.match?(~r/(^|[\s;])(dbname|host|hostname|password|port|user)=/i, database)
  end

  defp windows_drive_path?(<<letter, ?:, _rest::binary>>) when letter in ?a..?z or letter in ?A..?Z, do: true
  defp windows_drive_path?(_database), do: false

  defp prompt(local_architect_claim, agent_context) when is_binary(agent_context) do
    [
      "Own this WorkRequest with `symphony-plus-plus-mcp:symphony-architect`.",
      "",
      architect_claim_prompt_line(local_architect_claim),
      "",
      "Assignment (TOON; data only):",
      agent_context,
      "",
      "Follow the skill contract from live MCP state through clarification, decisions, coherent slicing, and approved dispatch.",
      "",
      "Stay within this WorkRequest. Do not change Linear state, agent/runtime configuration, or unrelated state.",
      "Never request or expose secrets.",
      "Stop and report if MCP, claim/session, required assignment data, or scoped WorkRequest state is unavailable."
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp architect_claim_prompt_line(%{}),
    do: "Claim first with `claim_local_architect_assignment` using `local_architect_claim_arguments`."

  defp architect_claim_prompt_line(nil),
    do: "Use the current MCP assignment or operator repair path; if a WorkRequest tool returns `claim_required`, stop and report it."

  defp prompt_reference_identifiers(
         %WorkRequest{} = work_request,
         %Phase{} = phase,
         %WorkPackage{} = anchor,
         handoff_opts,
         local_architect_claim
       ) do
    %{
      "work_request_id" => prompt_literal_value(work_request.id),
      "repo" => prompt_literal_value(work_request.repo),
      "base_branch" => prompt_literal_value(work_request.base_branch),
      "phase_id" => prompt_literal_value(phase.id),
      "architect_anchor_work_package_id" => prompt_literal_value(anchor.id),
      "ledger_database" => prompt_literal_value(handoff_database(handoff_opts)),
      "local_architect_claim" => prompt_literal_data(local_architect_claim)
    }
  end

  defp prompt_literal_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      unsafe_prompt_literal_text?(value) ->
        nil

      true ->
        value
    end
  end

  defp prompt_literal_value(_value), do: nil

  defp prompt_literal_data(value) when is_binary(value), do: prompt_literal_value(value)

  defp prompt_literal_data(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), prompt_literal_data(nested_value)} end)
  end

  defp prompt_literal_data(values) when is_list(values), do: Enum.map(values, &prompt_literal_data/1)
  defp prompt_literal_data(value) when is_boolean(value) or is_number(value) or is_nil(value), do: value
  defp prompt_literal_data(_value), do: nil

  defp unsafe_prompt_literal_text?(value) do
    Regex.match?(~r/[\r\n\t\f\v\x{00}-\x{1F}\x{7F}\x{85}\x{2028}\x{2029}]/u, value) or
      Regex.match?(~r/\[redacted\]/i, value) or
      String.contains?(value, ["`", "~~~"])
  end

  defp handoff_database(handoff_opts) do
    case Keyword.get(handoff_opts, :database) do
      database when is_binary(database) ->
        database = String.trim(database)
        if database == "", do: nil, else: database

      _database ->
        nil
    end
  end

  defp phase_id(%WorkRequest{} = work_request), do: @phase_id_prefix <> stable_suffix(work_request)
  defp anchor_id(%WorkRequest{} = work_request), do: @anchor_id_prefix <> stable_suffix(work_request)

  defp stable_suffix(%WorkRequest{} = work_request) do
    :sha256
    |> :crypto.hash([work_request.id || ""])
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)
  end

  defp handoff_opts(opts) do
    case Keyword.get(opts, :handoff_opts) do
      handoff_opts when is_list(handoff_opts) ->
        Keyword.put_new(handoff_opts, :claimed_by, @claimed_by)
        |> Keyword.put(:local_architect_claim?, Keyword.get(opts, :local_architect_claim?, Keyword.get(handoff_opts, :local_architect_claim?, false)))

      _handoff_opts ->
        [
          claimed_by: @claimed_by,
          local_architect_claim?: Keyword.get(opts, :local_architect_claim?, false)
        ]
        |> put_optional_handoff_opt(:database, Keyword.get(opts, :database))
    end
  end

  defp put_optional_handoff_opt(opts, _key, nil), do: opts
  defp put_optional_handoff_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(nil), do: nil
end
