defmodule SymphonyElixir.SymphonyPlusPlus.Planning.PlanNode do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.Id

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @statuses ["pending", "in_progress", "done", "skipped"]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_package_id: String.t() | nil,
          title: String.t() | nil,
          body: String.t() | nil,
          status: String.t() | nil,
          position: non_neg_integer() | nil,
          created_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_plan_nodes" do
    field(:work_package_id, :string)
    field(:title, :string)
    field(:body, :string)
    field(:status, :string)
    field(:position, :integer)
    field(:created_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("id", stable_id("plan"))
      |> put_new_value("status", "pending")
      |> put_new_value("created_at", DateTime.utc_now(:microsecond))

    %__MODULE__{}
    |> cast(attrs, [:id, :work_package_id, :title, :body, :status, :position, :created_at])
    |> validate_required([:id, :work_package_id, :title, :status, :position, :created_at])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint(:id, name: :sympp_plan_nodes_id_unique_index)
    |> foreign_key_constraint(:work_package_id)
  end

  @spec status_changeset(t(), map()) :: Ecto.Changeset.t()
  def status_changeset(%__MODULE__{} = plan_node, attrs) do
    plan_node
    |> cast(normalize_keys(attrs), [:status])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = plan_node, attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> Map.put_new("title", plan_node.title)
      |> Map.put_new("status", plan_node.status)

    plan_node
    |> cast(attrs, [:title, :body, :status])
    |> validate_required([:title, :status])
    |> validate_nonblank(:title)
    |> validate_inclusion(:status, @statuses)
  end

  defp validate_nonblank(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      if is_binary(value) and String.trim(value) == "" do
        [{field, "cannot be blank"}]
      else
        []
      end
    end)
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

  defp stable_id(prefix) do
    Id.random(prefix)
  end
end
