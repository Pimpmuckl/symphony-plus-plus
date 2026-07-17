defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Projection
  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.Repository

  @spec tree_for_work_request(module(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate tree_for_work_request(repo, work_request_id), to: Repository

  @spec create_node(module(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate create_node(repo, attrs), to: Repository

  @spec upsert_node(module(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate upsert_node(repo, attrs), to: Repository

  @spec create_dependency_edge(module(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate create_dependency_edge(repo, attrs), to: Repository

  @spec record_revision(module(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate record_revision(repo, work_request_id, attrs), to: Repository

  @spec project(module(), String.t(), [map()], keyword()) :: map()
  defdelegate project(repo, work_request_id, work_package_payloads, opts \\ []), to: Projection
end
