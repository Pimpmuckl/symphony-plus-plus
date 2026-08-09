defmodule SymphonyElixir.SymphonyPlusPlus.ProductTree do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.ProductTree.ExecutionGraph
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

  @spec upsert_dependency_edge(module(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate upsert_dependency_edge(repo, attrs), to: Repository

  @spec delete_dependency_edge(module(), String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  defdelegate delete_dependency_edge(repo, work_request_id, id), to: Repository

  @spec delete_group(module(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  defdelegate delete_group(repo, work_request_id, id), to: Repository

  @spec record_revision(module(), String.t(), map()) :: {:ok, term()} | {:error, term()}
  defdelegate record_revision(repo, work_request_id, attrs), to: Repository

  @spec project(module(), String.t(), [map()], keyword()) :: map()
  defdelegate project(repo, work_request_id, work_package_payloads, opts \\ []), to: Projection

  @spec execution_graph(module(), String.t()) :: {:ok, ExecutionGraph.graph()} | {:error, term()}
  defdelegate execution_graph(repo, work_request_id), to: ExecutionGraph, as: :evaluate

  @spec execution_graph(module(), String.t(), [map() | struct()]) :: {:ok, ExecutionGraph.graph()} | {:error, term()}
  defdelegate execution_graph(repo, work_request_id, work_packages), to: ExecutionGraph, as: :evaluate
end
