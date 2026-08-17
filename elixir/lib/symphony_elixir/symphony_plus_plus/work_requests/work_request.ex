defmodule SymphonyElixir.SymphonyPlusPlus.WorkRequests.WorkRequest do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.{BaseBranch, Id}

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @statuses [
    "draft",
    "ready_for_clarification",
    "clarifying",
    "ready_for_slicing",
    "human_info_needed",
    "sliced"
  ]

  @work_types [
    "feature",
    "bugfix",
    "hotfix",
    "refactor",
    "investigation",
    "docs",
    "review"
  ]

  @dispatch_shapes [
    "single_package",
    "architect_led_feature_branch",
    "direct_main_fix",
    "investigation_first"
  ]

  @creator_kinds ["human", "agent", "operator", "system"]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          title: String.t() | nil,
          repo: String.t() | nil,
          base_branch: String.t() | nil,
          work_type: String.t() | nil,
          human_description: String.t() | nil,
          constraints: map() | nil,
          desired_dispatch_shape: String.t() | nil,
          creator_kind: String.t() | nil,
          creator_name: String.t() | nil,
          created_via: String.t() | nil,
          status: String.t() | nil,
          completed_at: DateTime.t() | nil,
          completion_source: String.t() | nil,
          archived_at: DateTime.t() | nil,
          archive_reason: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_work_requests" do
    field(:title, :string)
    field(:repo, :string)
    field(:base_branch, :string)
    field(:work_type, :string)
    field(:human_description, :string)
    field(:constraints, :map, default: %{})
    field(:desired_dispatch_shape, :string)
    field(:creator_kind, :string)
    field(:creator_name, :string)
    field(:created_via, :string)
    field(:status, :string)
    field(:completed_at, :utc_datetime_usec)
    field(:completion_source, :string)
    field(:archived_at, :utc_datetime_usec)
    field(:archive_reason, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec work_types() :: [String.t()]
  def work_types, do: @work_types

  @spec dispatch_shapes() :: [String.t()]
  def dispatch_shapes, do: @dispatch_shapes

  @spec creator_kinds() :: [String.t()]
  def creator_kinds, do: @creator_kinds

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("id", stable_id())
      |> put_new_value("status", "draft")
      |> put_new_value("constraints", %{})
      |> Map.drop(["completed_at", "completion_source", "archived_at", "archive_reason"])

    %__MODULE__{}
    |> changeset(attrs)
    |> unique_constraint(:id, name: :sympp_work_requests_id_unique_index)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = work_request, attrs) do
    attrs = normalize_keys(attrs)

    work_request
    |> changeset(Map.drop(attrs, ["id", "status", "completed_at", "completion_source", "archived_at", "archive_reason", "inserted_at", "updated_at", "created_at"]))
    |> reject_generic_status_update(attrs)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = work_request, attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> BaseBranch.canonicalize_attrs()
      |> normalize_constraints()
      |> normalize_provenance()

    work_request
    |> cast(attrs, [
      :id,
      :title,
      :repo,
      :base_branch,
      :work_type,
      :human_description,
      :constraints,
      :desired_dispatch_shape,
      :creator_kind,
      :creator_name,
      :created_via,
      :status,
      :completed_at,
      :completion_source,
      :archived_at,
      :archive_reason
    ])
    |> validate_required([
      :id,
      :title,
      :repo,
      :base_branch,
      :work_type,
      :human_description,
      :constraints,
      :desired_dispatch_shape,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:work_type, @work_types)
    |> validate_inclusion(:desired_dispatch_shape, @dispatch_shapes)
    |> validate_optional_inclusion(:creator_kind, @creator_kinds)
    |> validate_json_safe_constraints()
  end

  defp reject_generic_status_update(changeset, attrs) do
    if Map.has_key?(attrs, "status") do
      add_error(changeset, :status, "use update_status/4 for status transitions")
    else
      changeset
    end
  end

  defp normalize_constraints(attrs) do
    case Map.fetch(attrs, "constraints") do
      {:ok, constraints} -> Map.put(attrs, "constraints", normalize_constraint_value(constraints))
      :error -> attrs
    end
  end

  defp normalize_provenance(attrs) do
    Enum.reduce(["creator_kind", "creator_name", "created_via"], attrs, fn key, attrs ->
      normalize_provenance_value(attrs, key, Map.get(attrs, key))
    end)
  end

  defp normalize_provenance_value(attrs, key, value) when is_binary(value) do
    case String.trim(value) do
      "" -> Map.put(attrs, key, nil)
      value -> Map.put(attrs, key, value)
    end
  end

  defp normalize_provenance_value(attrs, _key, _value), do: attrs

  defp validate_optional_inclusion(changeset, field, values) do
    validate_change(changeset, field, fn ^field, value ->
      if is_nil(value) or value in values, do: [], else: [{field, "is invalid"}]
    end)
  end

  defp normalize_constraint_value(%{__struct__: _} = value), do: value

  defp normalize_constraint_value(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} ->
      {normalize_constraint_key(key), normalize_constraint_value(nested_value)}
    end)
  end

  defp normalize_constraint_value(value) when is_list(value), do: Enum.map(value, &normalize_constraint_value/1)
  defp normalize_constraint_value(value), do: value

  defp normalize_constraint_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_constraint_key(key) when is_binary(key), do: key
  defp normalize_constraint_key(key), do: key

  defp validate_json_safe_constraints(changeset) do
    validate_change(changeset, :constraints, fn :constraints, value ->
      if json_safe_map?(value) do
        []
      else
        [constraints: "must be a JSON-safe map"]
      end
    end)
  end

  defp json_safe_map?(%{__struct__: _}), do: false

  defp json_safe_map?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested_value} ->
      is_binary(key) and json_safe_value?(nested_value)
    end)
  end

  defp json_safe_map?(_value), do: false

  defp json_safe_value?(%{__struct__: _}), do: false
  defp json_safe_value?(value) when is_binary(value), do: true
  defp json_safe_value?(value) when is_number(value), do: true
  defp json_safe_value?(value) when is_boolean(value), do: true
  defp json_safe_value?(nil), do: true
  defp json_safe_value?(value) when is_list(value), do: Enum.all?(value, &json_safe_value?/1)
  defp json_safe_value?(value) when is_map(value), do: json_safe_map?(value)
  defp json_safe_value?(_value), do: false

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
    Id.random("wr")
  end
end
