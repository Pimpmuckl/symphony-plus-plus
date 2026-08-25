defmodule SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.Repository do
  @moduledoc false

  import Ecto.Query, only: [from: 2]

  alias Ecto.Changeset
  alias SymphonyElixir.SymphonyPlusPlus.BaseBranch
  alias SymphonyElixir.SymphonyPlusPlus.GuidanceRequests.GuidanceRequest
  alias SymphonyElixir.SymphonyPlusPlus.Repo.Migrations
  alias SymphonyElixir.SymphonyPlusPlus.RepoIdentity
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage

  @type repo :: module()
  @type error ::
          :database_busy
          | :id_already_exists
          | :idempotency_key_conflict
          | :invalid_status
          | :not_found
          | {:constraint_failed, String.t()}
          | {:migration_failed, term()}
          | {:storage_failed, String.t()}
          | Changeset.t()

  @spec migrate(repo()) :: :ok | {:error, error()}
  def migrate(repo) when is_atom(repo) do
    Ecto.Migrator.run(repo, Migrations.all(), :up, all: true, log: false)
    :ok
  rescue
    error -> {:error, {:migration_failed, error}}
  end

  @spec create(repo(), map()) :: {:ok, GuidanceRequest.t()} | {:error, error()}
  def create(repo, attrs) when is_atom(repo) and is_map(attrs) do
    attrs
    |> GuidanceRequest.create_changeset()
    |> repo.insert()
    |> normalize_insert_result()
  rescue
    error in Ecto.ConstraintError -> normalize_constraint_error(error)
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get(repo(), String.t()) :: {:ok, GuidanceRequest.t()} | {:error, error()}
  def get(repo, id) when is_atom(repo) and is_binary(id) do
    case repo.get(GuidanceRequest, id) do
      nil -> {:error, :not_found}
      guidance_request -> {:ok, guidance_request}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec get_by_idempotency_key(repo(), String.t(), String.t(), String.t()) ::
          {:ok, GuidanceRequest.t()} | {:error, error()}
  def get_by_idempotency_key(repo, work_package_id, requester_grant_id, idempotency_key)
      when is_atom(repo) and is_binary(work_package_id) and is_binary(requester_grant_id) and
             is_binary(idempotency_key) do
    query =
      from(guidance_request in GuidanceRequest,
        where: guidance_request.work_package_id == ^work_package_id,
        where: guidance_request.requester_grant_id == ^requester_grant_id,
        where: guidance_request.idempotency_key == ^idempotency_key,
        limit: 1
      )

    case repo.one(query) do
      nil -> {:error, :not_found}
      guidance_request -> {:ok, guidance_request}
    end
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_visible_to_architect(repo(), map()) :: {:ok, [GuidanceRequest.t()]} | {:error, error()}
  def list_visible_to_architect(repo, filters) when is_atom(repo) and is_map(filters) do
    filters = normalize_keys(filters)
    work_package_ids = visible_to_architect_work_package_ids(repo, filters)

    guidance_requests =
      repo.all(
        work_package_ids
        |> visible_to_architect_query()
        |> maybe_filter_status(Map.get(filters, "status"))
        |> maybe_filter_work_packages(Map.get(filters, "filter_work_package_ids"))
        |> maybe_filter_work_package(Map.get(filters, "work_package_id"))
      )

    {:ok, guidance_requests}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec answer(repo(), String.t(), map()) :: {:ok, GuidanceRequest.t()} | {:error, error()}
  def answer(repo, id, attrs) when is_atom(repo) and is_binary(id) and is_map(attrs) do
    terminal_update(repo, id, attrs, "answered", "open", &GuidanceRequest.answer_changeset/2)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec answer_human_info_needed(repo(), String.t(), map()) :: {:ok, GuidanceRequest.t()} | {:error, error()}
  def answer_human_info_needed(repo, id, attrs) when is_atom(repo) and is_binary(id) and is_map(attrs) do
    terminal_update(repo, id, attrs, "answered", "human_info_needed", &GuidanceRequest.answer_changeset/2)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec escalate_human_info_needed(repo(), String.t(), map()) :: {:ok, GuidanceRequest.t()} | {:error, error()}
  def escalate_human_info_needed(repo, id, attrs) when is_atom(repo) and is_binary(id) and is_map(attrs) do
    terminal_update(repo, id, attrs, "human_info_needed", "open", &GuidanceRequest.escalate_changeset/2)
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  @spec list_for_work_package(repo(), String.t()) :: {:ok, [GuidanceRequest.t()]} | {:error, error()}
  def list_for_work_package(repo, work_package_id) when is_atom(repo) and is_binary(work_package_id) do
    query =
      from(guidance_request in GuidanceRequest,
        where: guidance_request.work_package_id == ^work_package_id,
        order_by: [asc: guidance_request.inserted_at, asc: guidance_request.id]
      )

    {:ok, repo.all(query)}
  rescue
    error in Exqlite.Error -> normalize_exqlite_error(error)
  end

  defp terminal_update(repo, id, attrs, status, current_status, changeset_fun) do
    changeset =
      %GuidanceRequest{id: id, status: current_status}
      |> changeset_fun.(Map.merge(normalize_keys(attrs), %{"status" => status}))

    if changeset.valid? do
      updates =
        changeset.changes
        |> Map.put(:updated_at, DateTime.utc_now(:microsecond))
        |> Map.to_list()

      query =
        from(guidance_request in GuidanceRequest,
          where: guidance_request.id == ^id,
          where: guidance_request.status == ^current_status
        )

      case repo.update_all(query, set: updates) do
        {1, _rows} -> get(repo, id)
        {0, _rows} -> terminal_update_miss(repo, id)
      end
    else
      {:error, changeset}
    end
  end

  defp terminal_update_miss(repo, id) do
    case get(repo, id) do
      {:ok, %GuidanceRequest{}} -> {:error, :invalid_status}
      {:error, _reason} = error -> error
    end
  end

  defp visible_to_architect_work_package_ids(
         repo,
         %{"phase_id" => phase_id, "repo" => repo_name, "base_branch" => base_branch} = filters
       ) do
    work_package_ids = normalized_work_package_ids(Map.get(filters, "work_package_ids"))

    repo.all(
      from(work_package in WorkPackage,
        where:
          work_package.phase_id == ^phase_id or
            (is_nil(work_package.phase_id) and work_package.id in ^work_package_ids),
        select: {work_package.id, work_package.repo, work_package.base_branch, work_package.phase_id}
      )
    )
    |> Enum.filter(fn {id, package_repo, package_base_branch, package_phase_id} ->
      (is_nil(package_phase_id) and id in work_package_ids) or
        (package_phase_id == phase_id and repo_scope_match?(repo_name, package_repo) and
           BaseBranch.equivalent?(base_branch, package_base_branch))
    end)
    |> Enum.map(fn {id, _repo, _base_branch, _phase_id} -> id end)
    |> Enum.uniq()
  end

  defp visible_to_architect_work_package_ids(_repo, _filters), do: []

  defp visible_to_architect_query(work_package_ids) do
    from(guidance_request in GuidanceRequest,
      where: guidance_request.work_package_id in ^work_package_ids,
      order_by: [asc: guidance_request.inserted_at, asc: guidance_request.id]
    )
  end

  defp repo_scope_match?(expected_repo, actual_repo) when is_binary(expected_repo) and is_binary(actual_repo) do
    RepoIdentity.scope_match?(expected_repo, actual_repo,
      trusted_remotes: repo_scope_trusted_remotes(),
      local_path_remotes?: true
    )
  end

  defp repo_scope_match?(_expected_repo, _actual_repo), do: false

  defp repo_scope_trusted_remotes do
    :symphony_elixir
    |> Application.get_env(:sympp_repo_identity_trusted_remotes, [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
  end

  defp normalized_work_package_ids(ids) when is_list(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalized_work_package_ids(_ids), do: []

  defp maybe_filter_status(query, status) when is_binary(status) and status != "" do
    from(guidance_request in query, where: guidance_request.status == ^status)
  end

  defp maybe_filter_status(query, _status), do: query

  defp maybe_filter_work_packages(query, ids) when is_list(ids) do
    case ids |> Enum.filter(&is_binary/1) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq() do
      [] -> from(guidance_request in query, where: false)
      work_package_ids -> from(guidance_request in query, where: guidance_request.work_package_id in ^work_package_ids)
    end
  end

  defp maybe_filter_work_packages(query, _ids), do: query

  defp maybe_filter_work_package(query, work_package_id) when is_binary(work_package_id) and work_package_id != "" do
    from(guidance_request in query, where: guidance_request.work_package_id == ^work_package_id)
  end

  defp maybe_filter_work_package(query, _work_package_id), do: query

  defp normalize_insert_result({:ok, guidance_request}), do: {:ok, guidance_request}

  defp normalize_insert_result({:error, %Changeset{} = changeset}) do
    cond do
      duplicate_id?(changeset) -> {:error, :id_already_exists}
      duplicate_idempotency_key?(changeset) -> {:error, :idempotency_key_conflict}
      true -> {:error, changeset}
    end
  end

  defp duplicate_id?(changeset), do: constraint_error?(changeset, :id, :unique)
  defp duplicate_idempotency_key?(changeset), do: constraint_error?(changeset, :idempotency_key, :unique)

  defp constraint_error?(changeset, field, constraint) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, options}} -> Keyword.get(options, :constraint) == constraint
      _error -> false
    end)
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_guidance_requests_id_unique_index"}) do
    {:error, :id_already_exists}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: "sympp_guidance_requests_worker_idempotency_key_unique_index"}) do
    {:error, :idempotency_key_conflict}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{constraint: constraint}) when is_binary(constraint) do
    {:error, {:constraint_failed, constraint}}
  end

  defp normalize_constraint_error(%Ecto.ConstraintError{type: type}) do
    {:error, {:constraint_failed, Atom.to_string(type)}}
  end

  defp normalize_exqlite_error(error) do
    message = Exception.message(error)
    normalized_message = String.downcase(message)

    if String.contains?(normalized_message, "busy") or String.contains?(normalized_message, "locked") do
      {:error, :database_busy}
    else
      {:error, {:storage_failed, message}}
    end
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)
end
