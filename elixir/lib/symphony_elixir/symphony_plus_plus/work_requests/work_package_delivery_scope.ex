defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDeliveryScope do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.RepoScope
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.Repository
  alias SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest

  @spec validate(module(), WorkRequest.t(), WorkPackage.t() | map()) :: :ok | {:error, term()}
  def validate(ecto_repo, %WorkRequest{} = work_request, %WorkPackage{} = work_package) do
    validate(ecto_repo, work_request, %{
      "repo" => work_package.repo,
      "base_branch" => work_package.base_branch
    })
  end

  def validate(ecto_repo, %WorkRequest{} = work_request, attrs) when is_atom(ecto_repo) and is_map(attrs) do
    case {nonblank_or_nil(Map.get(attrs, "repo")), nonblank_or_nil(Map.get(attrs, "base_branch"))} do
      {nil, _base_branch} ->
        :ok

      {delivery_repo, base_branch} when is_binary(delivery_repo) and is_binary(base_branch) ->
        validate_delivery_scope(ecto_repo, work_request, delivery_repo, base_branch)

      {_repo, _base_branch} ->
        :ok
    end
  end

  defp validate_delivery_scope(ecto_repo, %WorkRequest{} = work_request, delivery_repo, base_branch) do
    with {:ok, repo_scopes} <- Repository.list_repo_scopes(ecto_repo, work_request.id) do
      if Enum.any?(repo_scopes, &repo_scope_matches_delivery?(&1, delivery_repo, base_branch)) do
        :ok
      else
        {:error, :work_package_delivery_scope_out_of_scope}
      end
    end
  end

  defp repo_scope_matches_delivery?(%RepoScope{repo: scoped_repo, base_branch: nil}, delivery_repo, _base_branch),
    do: scoped_repo == delivery_repo

  defp repo_scope_matches_delivery?(%RepoScope{repo: scoped_repo, base_branch: scoped_branch}, delivery_repo, base_branch),
    do: scoped_repo == delivery_repo and scoped_branch == base_branch

  defp nonblank_or_nil(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp nonblank_or_nil(_value), do: nil
end
