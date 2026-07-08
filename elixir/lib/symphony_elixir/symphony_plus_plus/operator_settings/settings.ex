defmodule SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.OperatorSettings.Settings.HiddenWorkPackageIdList
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.StringList

  defmodule HiddenWorkPackageIdList do
    @moduledoc false

    @behaviour Ecto.Type

    @spec type() :: :string
    def type, do: StringList.type()

    @spec embed_as(term()) :: :self
    def embed_as(format), do: StringList.embed_as(format)

    @spec equal?(term(), term()) :: boolean()
    def equal?(left, right), do: StringList.equal?(left, right)

    @spec cast(term()) :: {:ok, [String.t()]} | :error
    def cast(value), do: StringList.cast(value)

    @spec dump(term()) :: {:ok, String.t()} | :error
    def dump(value), do: StringList.dump(value)

    @spec load(term()) :: {:ok, [String.t()]}
    def load(value) do
      case StringList.load(value) do
        {:ok, values} -> {:ok, values}
        :error -> {:ok, []}
      end
    end
  end

  @settings_id "local_operator"
  @default_work_request_archive_after_days 14
  @default_solo_session_delete_after_days 30
  @default_open_dashboard_on_boot true
  @max_work_request_archive_after_days 3650

  @primary_key {:id, :string, autogenerate: false}
  @type t :: %__MODULE__{
          id: String.t(),
          work_request_archive_after_days: pos_integer(),
          solo_session_delete_after_days: pos_integer(),
          open_dashboard_on_boot: boolean(),
          hidden_work_package_ids: [String.t()],
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_operator_settings" do
    field(:work_request_archive_after_days, :integer, default: @default_work_request_archive_after_days)
    field(:solo_session_delete_after_days, :integer, default: @default_solo_session_delete_after_days)
    field(:open_dashboard_on_boot, :boolean, default: @default_open_dashboard_on_boot)
    field(:hidden_work_package_ids, HiddenWorkPackageIdList, default: [])

    timestamps(type: :utc_datetime_usec)
  end

  @spec settings_id() :: String.t()
  def settings_id, do: @settings_id

  @spec default_work_request_archive_after_days() :: pos_integer()
  def default_work_request_archive_after_days, do: @default_work_request_archive_after_days

  @spec default_solo_session_delete_after_days() :: pos_integer()
  def default_solo_session_delete_after_days, do: @default_solo_session_delete_after_days

  @spec default_open_dashboard_on_boot() :: boolean()
  def default_open_dashboard_on_boot, do: @default_open_dashboard_on_boot

  @spec default() :: t()
  def default do
    %__MODULE__{
      id: @settings_id,
      work_request_archive_after_days: @default_work_request_archive_after_days,
      solo_session_delete_after_days: @default_solo_session_delete_after_days,
      open_dashboard_on_boot: @default_open_dashboard_on_boot,
      hidden_work_package_ids: []
    }
  end

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) when is_map(attrs) do
    %__MODULE__{}
    |> changeset(attrs |> normalize_keys() |> Map.put_new("id", @settings_id))
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = settings, attrs) when is_map(attrs) do
    settings
    |> changeset(attrs |> normalize_keys() |> Map.drop(["id", "inserted_at", "updated_at"]))
  end

  defp changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :id,
      :work_request_archive_after_days,
      :solo_session_delete_after_days,
      :open_dashboard_on_boot,
      :hidden_work_package_ids
    ])
    |> validate_required([
      :id,
      :work_request_archive_after_days,
      :solo_session_delete_after_days,
      :open_dashboard_on_boot
    ])
    |> validate_number(:work_request_archive_after_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_work_request_archive_after_days
    )
    |> validate_number(:solo_session_delete_after_days,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: @max_work_request_archive_after_days
    )
    |> validate_change(:hidden_work_package_ids, fn :hidden_work_package_ids, values ->
      if Enum.all?(values, &(is_binary(&1) and String.trim(&1) != "")) do
        []
      else
        [hidden_work_package_ids: "must contain nonblank strings"]
      end
    end)
    |> unique_constraint(:id, name: :sympp_operator_settings_id_unique_index)
  end

  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end
end
