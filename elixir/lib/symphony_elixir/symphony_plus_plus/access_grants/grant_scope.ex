defmodule SymphonyElixir.SymphonyPlusPlus.AccessGrants.GrantScope do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Scope
  alias SymphonyElixir.SymphonyPlusPlus.Id

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @scope_types ["ledger", "repo", "work_request", "work_package"]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          access_grant_id: String.t() | nil,
          scope_type: String.t() | nil,
          scope_key: String.t() | nil,
          scope_id: String.t() | nil,
          repo: String.t() | nil,
          base_branch: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_access_grant_scopes" do
    field(:access_grant_id, :string)
    field(:scope_type, :string)
    field(:scope_key, :string)
    field(:scope_id, :string)
    field(:repo, :string)
    field(:base_branch, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("id", stable_id())

    %__MODULE__{}
    |> cast(attrs, [:id, :access_grant_id, :scope_type, :scope_key, :scope_id, :repo, :base_branch])
    |> normalize_blank_strings()
    |> put_scope_key()
    |> validate_required([:id, :access_grant_id, :scope_type, :scope_key])
    |> validate_inclusion(:scope_type, @scope_types)
    |> validate_shape()
    |> unique_constraint(:scope_key, name: :sympp_access_grant_scopes_grant_key_unique_index)
  end

  @spec attrs_from_scope(String.t(), Scope.t()) :: map()
  def attrs_from_scope(access_grant_id, %Scope{} = scope) when is_binary(access_grant_id) do
    %{
      access_grant_id: access_grant_id,
      scope_type: scope.type |> Atom.to_string(),
      scope_id: scope.id,
      repo: scope.repo,
      base_branch: scope.base_branch
    }
  end

  @spec to_authorization_scope(t()) :: Scope.t()
  def to_authorization_scope(%__MODULE__{scope_type: "ledger"}), do: Scope.ledger()
  def to_authorization_scope(%__MODULE__{scope_type: "work_request", scope_id: id}), do: Scope.work_request(id)
  def to_authorization_scope(%__MODULE__{scope_type: "work_package", scope_id: id}), do: Scope.work_package(id)
  def to_authorization_scope(%__MODULE__{scope_type: "repo", repo: repo, base_branch: base_branch}), do: Scope.repo(repo, base_branch)

  @spec scope_key(Scope.t() | map()) :: String.t()
  def scope_key(%Scope{} = scope) do
    scope_key(attrs_from_scope("grant", scope))
  end

  def scope_key(%__MODULE__{} = scope) do
    %{
      scope_type: scope.scope_type,
      scope_id: scope.scope_id,
      repo: scope.repo,
      base_branch: scope.base_branch
    }
    |> scope_key()
  end

  def scope_key(%{} = attrs) do
    attrs = normalize_keys(attrs)

    case Map.fetch!(attrs, "scope_type") do
      "ledger" -> "ledger"
      "repo" -> "repo:#{Map.get(attrs, "repo")}:#{Map.get(attrs, "base_branch") || ""}"
      type when type in ["work_request", "work_package"] -> "#{type}:#{Map.get(attrs, "scope_id")}"
    end
  end

  defp validate_shape(changeset) do
    case get_field(changeset, :scope_type) do
      "ledger" -> changeset
      "repo" -> validate_required(changeset, [:repo])
      type when type in ["work_request", "work_package"] -> validate_required(changeset, [:scope_id])
      _type -> changeset
    end
  end

  defp put_scope_key(changeset) do
    scope_type = get_field(changeset, :scope_type)

    if is_binary(scope_type) and scope_type in @scope_types do
      put_change(changeset, :scope_key, scope_key(apply_changes(changeset)))
    else
      changeset
    end
  end

  defp normalize_blank_strings(changeset) do
    Enum.reduce([:scope_id, :repo, :base_branch], changeset, fn field, changeset ->
      normalize_blank_string_change(changeset, field, get_change(changeset, field))
    end)
  end

  defp normalize_blank_string_change(changeset, field, value) when is_binary(value) do
    value = String.trim(value)
    put_change(changeset, field, if(value == "", do: nil, else: value))
  end

  defp normalize_blank_string_change(changeset, _field, _value), do: changeset

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
    Id.random("ags")
  end
end
