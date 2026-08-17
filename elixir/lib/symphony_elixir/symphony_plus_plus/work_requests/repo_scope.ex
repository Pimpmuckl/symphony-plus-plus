defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.RepoScope do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.{BaseBranch, Id}

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_request_id: String.t() | nil,
          repo: String.t() | nil,
          base_branch: String.t() | nil,
          scope_key: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_work_request_repo_scopes" do
    field(:work_request_id, :string)
    field(:repo, :string)
    field(:base_branch, :string)
    field(:scope_key, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> normalize_scope_values()
      |> put_new_value("id", stable_id())
      |> put_scope_key()

    %__MODULE__{}
    |> cast(attrs, [:id, :work_request_id, :repo, :base_branch, :scope_key])
    |> validate_required([:id, :work_request_id, :repo, :scope_key])
    |> validate_change(:repo, &validate_nonblank_string/2)
    |> validate_change(:base_branch, &validate_optional_nonblank_string/2)
    |> unique_constraint(:scope_key, name: :sympp_work_request_repo_scopes_work_request_scope_key_unique_index)
  end

  @spec primary_attrs(String.t(), String.t(), String.t() | nil) :: map()
  def primary_attrs(work_request_id, repo, base_branch)
      when is_binary(work_request_id) and is_binary(repo) and (is_binary(base_branch) or is_nil(base_branch)) do
    %{"work_request_id" => work_request_id, "repo" => repo, "base_branch" => base_branch}
  end

  @spec scope_key(t() | map()) :: String.t()
  def scope_key(%__MODULE__{} = scope) do
    scope_key(%{"repo" => scope.repo, "base_branch" => scope.base_branch})
  end

  def scope_key(%{} = attrs) do
    attrs = attrs |> normalize_keys() |> normalize_scope_values()
    "repo:#{Map.get(attrs, "repo")}:#{Map.get(attrs, "base_branch") || ""}"
  end

  defp put_scope_key(%{"repo" => repo} = attrs) when is_binary(repo) do
    Map.put(attrs, "scope_key", scope_key(attrs))
  end

  defp put_scope_key(attrs), do: attrs

  defp validate_nonblank_string(field, value) when is_binary(value) do
    if String.trim(value) == "", do: [{field, "can't be blank"}], else: []
  end

  defp validate_nonblank_string(field, _value), do: [{field, "can't be blank"}]

  defp validate_optional_nonblank_string(_field, nil), do: []

  defp validate_optional_nonblank_string(field, value) when is_binary(value) do
    if String.trim(value) == "", do: [{field, "can't be blank"}], else: []
  end

  defp validate_optional_nonblank_string(field, _value), do: [{field, "can't be blank"}]

  defp normalize_scope_values(attrs) do
    attrs
    |> normalize_string_value("repo")
    |> BaseBranch.canonicalize_attrs()
  end

  defp normalize_string_value(attrs, key) do
    case Map.get(attrs, key) do
      value when is_binary(value) ->
        value = String.trim(value)
        Map.put(attrs, key, if(value == "", do: nil, else: value))

      _value ->
        attrs
    end
  end

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp put_new_value(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""] do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp stable_id do
    Id.random("wrrs")
  end
end
