defmodule SymphonyElixir.SymphonyPlusPlus.Comments.Comment do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.Id

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @target_kinds ["work_request", "work_package"]
  @source_types ["human", "operator", "architect", "worker", "ask_pro", "review"]
  @statuses ["open", "resolved"]
  @max_body_length 4_000
  @max_resolution_note_length 1_000

  @create_fields [
    :id,
    :target_kind,
    :target_id,
    :body,
    :source_type,
    :author_name,
    :status
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          target_kind: String.t() | nil,
          target_id: String.t() | nil,
          body: String.t() | nil,
          source_type: String.t() | nil,
          author_name: String.t() | nil,
          status: String.t() | nil,
          resolved_by: String.t() | nil,
          resolved_source_type: String.t() | nil,
          resolved_at: DateTime.t() | nil,
          resolution_note: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_comments" do
    field(:target_kind, :string)
    field(:target_id, :string)
    field(:body, :string)
    field(:source_type, :string)
    field(:author_name, :string)
    field(:status, :string)
    field(:resolved_by, :string)
    field(:resolved_source_type, :string)
    field(:resolved_at, :utc_datetime_usec)
    field(:resolution_note, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec target_kinds() :: [String.t()]
  def target_kinds, do: @target_kinds

  @spec source_types() :: [String.t()]
  def source_types, do: @source_types

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec max_body_length() :: pos_integer()
  def max_body_length, do: @max_body_length

  @spec max_resolution_note_length() :: pos_integer()
  def max_resolution_note_length, do: @max_resolution_note_length

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("id", stable_id())
      |> put_new_value("status", "open")

    %__MODULE__{}
    |> cast(attrs, @create_fields)
    |> validate_required(@create_fields)
    |> validate_nonblank(@create_fields)
    |> validate_inclusion(:target_kind, @target_kinds)
    |> validate_inclusion(:source_type, @source_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:body, max: @max_body_length)
    |> validate_create_status()
    |> unique_constraint(:id, name: :sympp_comments_id_unique_index)
  end

  @spec resolve_changeset(t(), map()) :: Ecto.Changeset.t()
  def resolve_changeset(%__MODULE__{} = comment, attrs) do
    comment
    |> cast(normalize_keys(attrs), [:status, :resolved_by, :resolved_source_type, :resolved_at, :resolution_note])
    |> validate_required([:status, :resolved_by, :resolved_source_type, :resolved_at])
    |> validate_nonblank([:resolved_by, :resolved_source_type])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:resolved_source_type, @source_types)
    |> validate_length(:resolution_note, max: @max_resolution_note_length)
    |> validate_resolved_status()
  end

  defp validate_create_status(changeset) do
    validate_change(changeset, :status, fn
      :status, "open" -> []
      :status, _status -> [status: "must be open on create"]
    end)
  end

  defp validate_resolved_status(changeset) do
    validate_change(changeset, :status, fn
      :status, "resolved" -> []
      :status, _status -> [status: "must be resolved"]
    end)
  end

  defp validate_nonblank(changeset, fields) do
    Enum.reduce(fields, changeset, &validate_nonblank_field/2)
  end

  defp validate_nonblank_field(field, changeset), do: validate_change(changeset, field, &nonblank_errors/2)

  defp nonblank_errors(field, value) when is_binary(value) do
    if String.trim(value) == "", do: [{field, "cannot be blank"}], else: []
  end

  defp nonblank_errors(_field, _value), do: []

  defp normalize_keys(attrs) when is_map(attrs) do
    Map.new(attrs, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)

  defp put_new_value(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""], do: Map.put(attrs, key, value), else: attrs
  end

  defp stable_id do
    Id.random("comment")
  end
end
