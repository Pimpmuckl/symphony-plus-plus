defmodule SymphonyElixir.SymphonyPlusPlus.AccessGrants.AccessGrant do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.Id
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.StringList

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string
  @derive {Inspect, except: [:secret_hash]}

  @roles ["worker", "architect"]
  @provenances ["child_worker_delegation"]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_package_id: String.t() | nil,
          phase_id: String.t() | nil,
          scope_repo: String.t() | nil,
          scope_base_branch: String.t() | nil,
          display_key: String.t() | nil,
          secret_hash: String.t() | nil,
          grant_role: String.t() | nil,
          provenance: String.t() | nil,
          capabilities: [String.t()] | nil,
          expires_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          claimed_at: DateTime.t() | nil,
          claimed_by: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_access_grants" do
    field(:work_package_id, :string)
    field(:phase_id, :string)
    field(:scope_repo, :string)
    field(:scope_base_branch, :string)
    field(:display_key, :string)
    field(:secret_hash, :string)
    field(:grant_role, :string)
    field(:provenance, :string)
    field(:capabilities, StringList, default: [])
    field(:expires_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    field(:claimed_at, :utc_datetime_usec)
    field(:claimed_by, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec roles() :: [String.t()]
  def roles, do: @roles

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.drop(["claimed_at", "claimed_by", "revoked_at", "inserted_at", "updated_at"])
      |> put_new_value("id", stable_id())
      |> put_new_value("grant_role", "worker")
      |> put_new_value("capabilities", [])

    %__MODULE__{}
    |> changeset(attrs)
    |> unique_constraint(:id, name: :sympp_access_grants_id_unique_index)
    |> unique_constraint(:secret_hash, name: :sympp_access_grants_secret_hash_unique_index)
  end

  @spec claim_changeset(t(), map()) :: Ecto.Changeset.t()
  def claim_changeset(%__MODULE__{} = access_grant, attrs) do
    access_grant
    |> cast(normalize_keys(attrs), [:claimed_at, :claimed_by])
    |> validate_required([:claimed_at, :claimed_by])
  end

  @spec revoke_changeset(t(), DateTime.t()) :: Ecto.Changeset.t()
  def revoke_changeset(%__MODULE__{revoked_at: %DateTime{}} = access_grant, %DateTime{}) do
    change(access_grant)
  end

  def revoke_changeset(%__MODULE__{} = access_grant, %DateTime{} = revoked_at) do
    access_grant
    |> change(revoked_at: utc_datetime_usec(revoked_at))
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = access_grant, attrs) do
    access_grant
    |> cast(normalize_keys(attrs), [
      :id,
      :work_package_id,
      :phase_id,
      :scope_repo,
      :scope_base_branch,
      :display_key,
      :secret_hash,
      :grant_role,
      :provenance,
      :capabilities,
      :expires_at,
      :revoked_at,
      :claimed_at,
      :claimed_by
    ])
    |> validate_required([
      :id,
      :work_package_id,
      :display_key,
      :secret_hash,
      :grant_role,
      :capabilities
    ])
    |> validate_length(:display_key, is: 4)
    |> validate_length(:secret_hash, is: 64)
    |> validate_inclusion(:grant_role, @roles)
    |> validate_inclusion(:provenance, @provenances)
    |> validate_scope()
    |> validate_worker_capabilities()
  end

  defp validate_scope(changeset) do
    role = get_field(changeset, :grant_role)
    work_package_id = string_scope(get_field(changeset, :work_package_id))
    phase_id = string_scope(get_field(changeset, :phase_id))
    capabilities = get_field(changeset, :capabilities, [])

    changeset
    |> validate_worker_scope(role, work_package_id, phase_id)
    |> validate_architect_phase_scope(role, capabilities, work_package_id, phase_id)
  end

  defp validate_worker_scope(changeset, "worker", nil, _phase_id), do: add_error(changeset, :work_package_id, "can't be blank")

  defp validate_worker_scope(changeset, "worker", _work_package_id, phase_id) when not is_nil(phase_id),
    do: add_error(changeset, :phase_id, "worker grants cannot be phase scoped")

  defp validate_worker_scope(changeset, _role, _work_package_id, _phase_id), do: changeset

  defp validate_architect_phase_scope(changeset, "architect", capabilities, work_package_id, phase_id) do
    if phase_scoped_architect_capabilities?(capabilities) do
      changeset
      |> require_architect_phase_anchor(work_package_id)
      |> require_architect_phase_scope(phase_id)
    else
      changeset
    end
  end

  defp validate_architect_phase_scope(changeset, _role, _capabilities, _work_package_id, _phase_id), do: changeset

  defp phase_scoped_architect_capabilities?(capabilities) when is_list(capabilities) do
    Enum.any?(
      capabilities,
      &(&1 in [
          "read:phase",
          "read:work_request",
          "write:work_request",
          "dispatch:work_request",
          "read:guidance_request",
          "write:guidance_request"
        ])
    )
  end

  defp phase_scoped_architect_capabilities?(_capabilities), do: false

  defp require_architect_phase_anchor(changeset, nil),
    do: add_error(changeset, :work_package_id, "architect phase-scoped grants require work package anchor")

  defp require_architect_phase_anchor(changeset, _work_package_id), do: changeset

  defp require_architect_phase_scope(changeset, nil),
    do: add_error(changeset, :phase_id, "architect phase-scoped grants require phase scope")

  defp require_architect_phase_scope(changeset, _phase_id), do: changeset

  defp string_scope(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_scope(_value), do: nil

  defp validate_worker_capabilities(changeset) do
    role = get_field(changeset, :grant_role)
    capabilities = get_field(changeset, :capabilities, [])

    if role == "worker" and Enum.any?(capabilities, &architect_capability?/1) do
      add_error(changeset, :capabilities, "worker grants cannot include architect capabilities")
    else
      changeset
    end
  end

  defp architect_capability?(capability) when is_binary(capability) do
    capability == "architect" or
      String.starts_with?(capability, ["architect:", "architect."]) or
      capability in [
        "read:phase",
        "read:work_request",
        "write:work_request",
        "dispatch:work_request",
        "read:guidance_request",
        "write:guidance_request",
        "write:phase_plan"
      ]
  end

  defp architect_capability?(_capability), do: false

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
    Id.random("ag")
  end

  defp utc_datetime_usec(%DateTime{} = datetime) do
    datetime = DateTime.truncate(datetime, :microsecond)
    %{datetime | microsecond: {elem(datetime.microsecond, 0), 6}}
  end
end
