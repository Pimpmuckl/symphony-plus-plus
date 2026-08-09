defmodule SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Service do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.ClaimLease
  alias SymphonyElixir.SymphonyPlusPlus.ClaimLeases.Repository

  @database_busy_retry_delay_ms 5

  @type error :: Repository.error()

  @spec claim(Repository.repo(), String.t(), map(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def claim(repo, work_package_id, actor, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_map(actor) and is_list(opts) do
    attrs =
      actor_attrs(actor)
      |> Map.merge(lease_attrs(opts))
      |> Map.put("work_package_id", work_package_id)

    Repository.claim(repo, attrs, opts)
  end

  @spec current_for_work_package(Repository.repo(), String.t()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def current_for_work_package(repo, work_package_id), do: Repository.current_for_work_package(repo, work_package_id)

  @spec heartbeat(Repository.repo(), String.t(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def heartbeat(repo, claim_lease_id, opts \\ []) when is_atom(repo) and is_binary(claim_lease_id) and is_list(opts) do
    retry_database_busy(fn -> Repository.heartbeat(repo, claim_lease_id, lease_attrs(opts), opts) end)
  end

  @spec pause(Repository.repo(), String.t(), map(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def pause(repo, claim_lease_id, actor, opts \\ [])
      when is_atom(repo) and is_binary(claim_lease_id) and is_map(actor) and is_list(opts) do
    Repository.pause(
      repo,
      claim_lease_id,
      %{
        paused_by_actor_id: actor_id(actor),
        pause_reason: Keyword.get(opts, :reason)
      },
      opts
    )
  end

  @spec release(Repository.repo(), String.t(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def release(repo, claim_lease_id, opts \\ []) when is_atom(repo) and is_binary(claim_lease_id) and is_list(opts) do
    Repository.release(repo, claim_lease_id, %{release_reason: Keyword.get(opts, :reason)}, opts)
  end

  @spec reclaim_stale(Repository.repo(), String.t(), map(), keyword()) :: {:ok, ClaimLease.t()} | {:error, error()}
  def reclaim_stale(repo, work_package_id, actor, opts \\ [])
      when is_atom(repo) and is_binary(work_package_id) and is_map(actor) and is_list(opts) do
    attrs =
      actor_attrs(actor)
      |> Map.merge(lease_attrs(opts))
      |> Map.merge(%{
        "reclaim_reason" => Keyword.get(opts, :reason),
        "stale_reason" => Keyword.get(opts, :stale_reason) || Keyword.get(opts, :reason)
      })

    retry_database_busy(fn -> Repository.reclaim_stale(repo, work_package_id, attrs, opts) end)
  end

  defp retry_database_busy(operation, retries_left \\ 1)

  defp retry_database_busy(operation, retries_left) do
    case operation.() do
      {:error, :database_busy} when retries_left > 0 ->
        Process.sleep(@database_busy_retry_delay_ms)
        retry_database_busy(operation, retries_left - 1)

      result ->
        result
    end
  end

  defp lease_attrs(opts) do
    Enum.reduce([:access_grant_id, :actor_display_name, :lease_expires_at, :stale_after_ms], %{}, fn key, attrs ->
      case Keyword.fetch(opts, key) do
        {:ok, value} -> Map.put(attrs, Atom.to_string(key), value)
        :error -> attrs
      end
    end)
  end

  defp actor_attrs(actor) do
    actor
    |> normalize_keys()
    |> Map.take(~w(actor_kind actor_id actor_display_name))
  end

  defp normalize_keys(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp actor_id(%{actor_id: actor_id}), do: actor_id
  defp actor_id(%{"actor_id" => actor_id}), do: actor_id
  defp actor_id(_actor), do: nil
end
