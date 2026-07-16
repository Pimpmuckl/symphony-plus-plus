defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.Target do
  @moduledoc false

  @enforce_keys [:type]
  defstruct [
    :type,
    :id,
    :repo,
    :base_branch,
    :phase_id,
    :work_request_id,
    :work_package_id,
    repo_scopes: [],
    resolution: :resolved,
    metadata: %{}
  ]

  @type type ::
          :ledger
          | :repo
          | :work_request
          | :work_package
          | :task_plan
          | :progress
          | :finding
          | :validation_note
          | :review_evidence
          | :blocker
          | :comment
          | :guidance_request
          | :delivery_board
          | :delivery_closeout
          | :dashboard

  @type resolution :: :resolved | :not_found | :ambiguous | :runtime_lease_conflict

  @type t :: %__MODULE__{
          type: type(),
          id: String.t() | nil,
          repo: String.t() | nil,
          base_branch: String.t() | nil,
          repo_scopes: [repo_scope()],
          phase_id: String.t() | nil,
          work_request_id: String.t() | nil,
          work_package_id: String.t() | nil,
          resolution: resolution(),
          metadata: map()
        }

  @type repo_scope :: %{repo: String.t(), base_branch: String.t() | nil}

  @spec ledger(keyword()) :: t()
  def ledger(opts \\ []), do: new(:ledger, nil, opts)

  @spec repo(String.t(), String.t() | nil, keyword()) :: t()
  def repo(repo, base_branch \\ nil, opts \\ []) when is_binary(repo) do
    new(:repo, nil, Keyword.merge(opts, repo: repo, base_branch: base_branch))
  end

  @spec work_request(String.t(), keyword()) :: t()
  def work_request(id, opts \\ []) when is_binary(id) do
    new(:work_request, id, Keyword.put(opts, :work_request_id, id))
  end

  @spec work_package(String.t(), String.t(), keyword()) :: t()
  def work_package(id, work_request_id, opts) when is_binary(id) and is_binary(work_request_id) and is_list(opts) do
    opts =
      opts
      |> Keyword.put(:work_request_id, work_request_id)
      |> Keyword.put(:work_package_id, id)

    new(:work_package, id, opts)
  end

  @spec work_package(String.t(), keyword() | String.t()) :: t()
  def work_package(id, opts \\ []) when is_binary(id) do
    if is_binary(opts) do
      work_package(id, opts, [])
    else
      new(:work_package, id, Keyword.put(opts, :work_package_id, id))
    end
  end

  @spec package_resource(type(), String.t(), keyword()) :: t()
  def package_resource(type, work_package_id, opts \\ [])
      when type in [
             :task_plan,
             :progress,
             :finding,
             :validation_note,
             :review_evidence,
             :blocker,
             :comment,
             :guidance_request
           ] and
             is_binary(work_package_id) do
    opts = Keyword.put(opts, :work_package_id, work_package_id)
    new(type, Keyword.get(opts, :id), opts)
  end

  @spec new(type(), String.t() | nil, keyword()) :: t()
  def new(type, id \\ nil, opts \\ []) do
    %__MODULE__{
      type: type,
      id: id,
      repo: Keyword.get(opts, :repo),
      base_branch: Keyword.get(opts, :base_branch),
      repo_scopes: normalize_repo_scopes(Keyword.get(opts, :repo_scopes, [])),
      phase_id: Keyword.get(opts, :phase_id),
      work_request_id: Keyword.get(opts, :work_request_id),
      work_package_id: Keyword.get(opts, :work_package_id),
      resolution: Keyword.get(opts, :resolution, :resolved),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @spec resolved?(t()) :: boolean()
  def resolved?(%__MODULE__{resolution: :resolved}), do: true
  def resolved?(%__MODULE__{}), do: false

  defp normalize_repo_scopes(scopes) when is_list(scopes) do
    Enum.flat_map(scopes, &normalize_repo_scope/1)
  end

  defp normalize_repo_scopes(_scopes), do: []

  defp normalize_repo_scope(%{repo: repo} = scope) when is_binary(repo) do
    [%{repo: repo, base_branch: Map.get(scope, :base_branch) || Map.get(scope, "base_branch")}]
  end

  defp normalize_repo_scope(%{"repo" => repo} = scope) when is_binary(repo) do
    [%{repo: repo, base_branch: Map.get(scope, "base_branch") || Map.get(scope, :base_branch)}]
  end

  defp normalize_repo_scope(_scope), do: []
end
