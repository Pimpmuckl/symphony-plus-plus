defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.Scope do
  @moduledoc false

  @enforce_keys [:type]
  defstruct [:type, :id, :repo, :base_branch, metadata: %{}]

  @type type :: :ledger | :work_request | :work_package | :repo | :phase

  @type t :: %__MODULE__{
          type: type(),
          id: String.t() | nil,
          repo: String.t() | nil,
          base_branch: String.t() | nil,
          metadata: map()
        }

  @spec ledger(keyword()) :: t()
  def ledger(opts \\ []), do: new(:ledger, nil, opts)

  @spec work_request(String.t(), keyword()) :: t()
  def work_request(id, opts \\ []) when is_binary(id), do: new(:work_request, id, opts)

  @spec work_package(String.t(), keyword()) :: t()
  def work_package(id, opts \\ []) when is_binary(id), do: new(:work_package, id, opts)

  @spec repo(String.t(), String.t() | nil, keyword()) :: t()
  def repo(repo, base_branch \\ nil, opts \\ []) when is_binary(repo) do
    new(:repo, nil, Keyword.merge(opts, repo: repo, base_branch: base_branch))
  end

  @spec phase(String.t(), keyword()) :: t()
  def phase(id, opts \\ []) when is_binary(id), do: new(:phase, id, opts)

  @spec new(type(), String.t() | nil, keyword()) :: t()
  def new(type, id \\ nil, opts \\ []) when type in [:ledger, :work_request, :work_package, :repo, :phase] do
    %__MODULE__{
      type: type,
      id: id,
      repo: Keyword.get(opts, :repo),
      base_branch: Keyword.get(opts, :base_branch),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end
