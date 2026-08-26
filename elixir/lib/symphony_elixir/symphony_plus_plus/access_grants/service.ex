defmodule SymphonyElixir.SymphonyPlusPlus.AccessGrants.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Assignment
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.Repository
  alias SymphonyElixir.SymphonyPlusPlus.AccessGrants.WorkKey
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.Repository, as: WorkPackageRepository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.ArchitectHandoff

  @default_worker_capabilities ["worker:claim", "worker:lifecycle.transition"]
  @default_architect_capabilities ["read:phase"]
  @pre_dispatch_work_package_statuses ["planned", "skipped"]
  @terminal_work_package_statuses ["merged", "closed", "abandoned"]
  @non_claimable_work_package_statuses @pre_dispatch_work_package_statuses ++ @terminal_work_package_statuses
  @claim_database_busy_retries 5
  @claim_database_busy_retry_delay_ms 5

  @type minted_grant :: %{grant: AccessGrant.t(), work_key: WorkKey.t()}
  @type error ::
          Repository.error()
          | WorkPackageRepository.error()
          | :missing_work_package_id
          | :outside_phase_scope
          | :work_package_not_dispatched
          | :work_package_terminal

  @spec mint_worker_grant(Repository.repo(), String.t(), keyword() | map()) ::
          {:ok, minted_grant()} | {:error, error()}
  def mint_worker_grant(repo, work_package_id, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and (is_list(opts) or is_map(opts)) do
    opts = normalize_options(opts)
    expires_at = option(opts, :expires_at, nil)
    capabilities = option(opts, :capabilities, @default_worker_capabilities)
    provenance = option(opts, :provenance, nil)
    work_key = WorkKey.generate()

    with :ok <- Repository.validate_work_package(repo, work_package_id),
         :ok <- require_claimable_worker_package(repo, work_package_id),
         {:ok, grant} <-
           Repository.create(
             repo,
             %{
               work_package_id: work_package_id,
               display_key: work_key.display_key,
               secret_hash: WorkKey.secret_hash(work_key.secret),
               grant_role: "worker",
               provenance: provenance,
               capabilities: capabilities,
               expires_at: truncate_expires_at(expires_at)
             },
             terminal_work_package_statuses: @non_claimable_work_package_statuses
           ) do
      {:ok, %{grant: grant, work_key: work_key}}
    end
  end

  @spec mint_architect_grant(Repository.repo(), String.t(), keyword() | map()) ::
          {:ok, minted_grant()} | {:error, error()}
  def mint_architect_grant(repo, phase_id, opts \\ [])
      when is_atom(repo) and is_binary(phase_id) and (is_list(opts) or is_map(opts)) do
    opts = normalize_options(opts)
    expires_at = option(opts, :expires_at, nil)
    capabilities = option(opts, :capabilities, @default_architect_capabilities)
    work_package_id = option(opts, :work_package_id, nil)
    work_request_id = option(opts, :work_request_id, nil)
    work_key = WorkKey.generate()

    with {:ok, work_package_id} <- required_work_package_id(work_package_id),
         :ok <- Repository.validate_phase(repo, phase_id),
         :ok <- validate_phase_anchor(repo, work_package_id, phase_id),
         {:ok, grant} <-
           Repository.create(repo, %{
             work_package_id: work_package_id,
             phase_id: phase_id,
             display_key: work_key.display_key,
             secret_hash: WorkKey.secret_hash(work_key.secret),
             grant_role: "architect",
             capabilities: capabilities,
             work_request_id: work_request_id,
             expires_at: truncate_expires_at(expires_at)
           }) do
      {:ok, %{grant: grant, work_key: work_key}}
    end
  end

  defp required_work_package_id(work_package_id) when is_binary(work_package_id) do
    work_package_id = String.trim(work_package_id)
    if work_package_id == "", do: {:error, :missing_work_package_id}, else: {:ok, work_package_id}
  end

  defp required_work_package_id(_work_package_id), do: {:error, :missing_work_package_id}

  defp validate_phase_anchor(repo, work_package_id, phase_id) do
    with {:ok, work_package} <- WorkPackageRepository.get(repo, work_package_id) do
      if work_package.phase_id == phase_id do
        :ok
      else
        {:error, :outside_phase_scope}
      end
    end
  end

  @spec claim(Repository.repo(), String.t(), keyword() | map()) :: {:ok, Assignment.t()} | {:error, error()}
  def claim(repo, secret, opts \\ []) when is_atom(repo) and is_binary(secret) and (is_list(opts) or is_map(opts)) do
    opts = normalize_options(opts)
    claim(repo, secret, opts, @claim_database_busy_retries)
  end

  defp claim(repo, secret, opts, retries_remaining) do
    now = option(opts, :now, DateTime.utc_now(:microsecond))

    result =
      with :ok <- reject_display_key_only(secret),
           {:ok, grant} <- Repository.find_by_secret_hash(repo, WorkKey.secret_hash(secret)),
           :ok <- require_live_package_authority(repo, grant) do
        Repository.claim(repo, secret, %{claimed_by: option(opts, :claimed_by, nil)}, now, terminal_work_package_statuses: @non_claimable_work_package_statuses)
      end

    case result do
      {:error, :database_busy} when retries_remaining > 0 ->
        Process.sleep(@claim_database_busy_retry_delay_ms)
        claim(repo, secret, opts, retries_remaining - 1)

      result ->
        result
    end
  end

  @spec claim_local_worker_grant(Repository.repo(), String.t(), keyword() | map()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def claim_local_worker_grant(repo, work_package_id, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and (is_list(opts) or is_map(opts)) do
    opts = normalize_options(opts)
    claim_local_worker_grant(repo, work_package_id, opts, @claim_database_busy_retries)
  end

  defp claim_local_worker_grant(repo, work_package_id, opts, retries_remaining) do
    now = option(opts, :now, DateTime.utc_now(:microsecond))

    result =
      with :ok <- require_claimable_worker_package(repo, work_package_id) do
        Repository.claim_local_worker_grant(
          repo,
          work_package_id,
          %{claimed_by: option(opts, :claimed_by, nil)},
          now,
          terminal_work_package_statuses: @non_claimable_work_package_statuses
        )
      end

    case result do
      {:error, :database_busy} when retries_remaining > 0 ->
        Process.sleep(@claim_database_busy_retry_delay_ms)
        claim_local_worker_grant(repo, work_package_id, opts, retries_remaining - 1)

      result ->
        result
    end
  end

  @spec claim_local_architect_grant(Repository.repo(), String.t(), String.t(), keyword() | map()) ::
          {:ok, AccessGrant.t()} | {:error, error()}
  def claim_local_architect_grant(repo, work_package_id, phase_id, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_binary(phase_id) and (is_list(opts) or is_map(opts)) do
    opts = normalize_options(opts)
    claim_local_architect_grant(repo, work_package_id, phase_id, opts, @claim_database_busy_retries)
  end

  defp claim_local_architect_grant(repo, work_package_id, phase_id, opts, retries_remaining) do
    now = option(opts, :now, DateTime.utc_now(:microsecond))

    result =
      Repository.claim_local_architect_grant(
        repo,
        work_package_id,
        phase_id,
        %{
          claimed_by: option(opts, :claimed_by, nil),
          scope_repo: option(opts, :scope_repo, nil),
          scope_base_branch: option(opts, :scope_base_branch, nil),
          work_request_id: option(opts, :work_request_id, nil),
          work_package_id: option(opts, :work_package_id, nil)
        },
        now,
        terminal_work_package_statuses: @terminal_work_package_statuses
      )

    case result do
      {:error, :database_busy} when retries_remaining > 0 ->
        Process.sleep(@claim_database_busy_retry_delay_ms)
        claim_local_architect_grant(repo, work_package_id, phase_id, opts, retries_remaining - 1)

      result ->
        result
    end
  end

  @spec revoke(Repository.repo(), String.t(), keyword() | map()) :: {:ok, AccessGrant.t()} | {:error, error()}
  def revoke(repo, id, opts \\ []) when is_atom(repo) and is_binary(id) and (is_list(opts) or is_map(opts)) do
    opts = normalize_options(opts)
    Repository.revoke(repo, id, option(opts, :now, DateTime.utc_now(:microsecond)))
  end

  @spec require_live_package_authority(Repository.repo(), AccessGrant.t()) :: :ok | {:error, error()}
  def require_live_package_authority(repo, %AccessGrant{grant_role: "architect"} = grant) when is_atom(repo) do
    case ArchitectHandoff.handoff_phase_grant?(repo, grant) do
      {:ok, true} -> :ok
      {:ok, false} -> require_claimable_worker_package(repo, grant.work_package_id)
      {:error, reason} -> {:error, reason}
    end
  end

  def require_live_package_authority(repo, %AccessGrant{work_package_id: work_package_id}) when is_atom(repo) and is_binary(work_package_id) do
    require_claimable_worker_package(repo, work_package_id)
  end

  def require_live_package_authority(_repo, %AccessGrant{}), do: {:error, :missing_work_package_id}

  defp require_claimable_worker_package(repo, work_package_id) do
    case Repository.work_package_authority_state(repo, work_package_id) do
      {:ok, %{delivered?: true}} ->
        {:error, :work_package_terminal}

      {:ok, %{status: status}} when status in @pre_dispatch_work_package_statuses ->
        {:error, :work_package_not_dispatched}

      {:ok, %{status: status}} when status in @terminal_work_package_statuses ->
        {:error, :work_package_terminal}

      {:ok, _state} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_options(opts) when is_list(opts), do: Map.new(opts)
  defp normalize_options(opts) when is_map(opts), do: opts

  defp truncate_expires_at(%DateTime{} = expires_at), do: DateTime.truncate(expires_at, :microsecond)
  defp truncate_expires_at(nil), do: nil

  defp reject_display_key_only(secret) do
    if String.length(secret) == 4 do
      {:error, :display_key_only}
    else
      :ok
    end
  end

  defp option(opts, key, default) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key)) || default
  end
end
