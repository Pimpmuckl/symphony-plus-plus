defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackageDelivery do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.Id

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @outcomes ["pr_merged", "completed_no_pr", "superseded", "abandoned"]

  @evidence_contract %{
    "pr_merged" => [
      %{name: "pr_url", type: :string, required: true, description: "Merged pull request URL."},
      %{name: "pr_number", type: :positive_integer, required: false, description: "Optional positive pull request number."},
      %{name: "pr_repository", type: :string, required: false, description: "Optional owner/repository."},
      %{name: "pr_merged_at", type: :string, required: true, description: "ISO-8601 merge timestamp."},
      %{name: "merge_commit_sha", type: :string, required: true, description: "Merge commit SHA."}
    ],
    "completed_no_pr" => [
      %{name: "no_pr_evidence", type: :string, required: true, description: "Markdown evidence for direct no-PR completion."}
    ],
    "superseded" => [
      %{
        name: "successor_work_package_id",
        type: :string,
        required: true,
        description: "Successor WorkPackage id in the same WorkRequest."
      },
      %{name: "superseded_reason", type: :string, required: true, description: "Markdown reason for supersession."}
    ],
    "abandoned" => [
      %{name: "abandoned_rationale", type: :string, required: true, description: "Markdown rationale for abandonment."}
    ]
  }

  @type evidence_field_spec :: %{
          name: String.t(),
          type: :string | :positive_integer,
          required: boolean(),
          description: String.t()
        }

  @type t :: %__MODULE__{
          id: String.t() | nil,
          work_request_id: String.t() | nil,
          work_package_id: String.t() | nil,
          outcome: String.t() | nil,
          idempotency_key: String.t() | nil,
          recorded_by: String.t() | nil,
          recorded_at: DateTime.t() | nil,
          pr_url: String.t() | nil,
          pr_number: pos_integer() | nil,
          pr_repository: String.t() | nil,
          pr_merged_at: DateTime.t() | nil,
          merge_commit_sha: String.t() | nil,
          no_pr_evidence: String.t() | nil,
          successor_work_package_id: String.t() | nil,
          superseded_reason: String.t() | nil,
          abandoned_rationale: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_work_package_deliveries" do
    field(:work_request_id, :string)
    field(:work_package_id, :string)
    field(:outcome, :string)
    field(:idempotency_key, :string)
    field(:recorded_by, :string)
    field(:recorded_at, :utc_datetime_usec)
    field(:pr_url, :string)
    field(:pr_number, :integer)
    field(:pr_repository, :string)
    field(:pr_merged_at, :utc_datetime_usec)
    field(:merge_commit_sha, :string)
    field(:no_pr_evidence, :string)
    field(:successor_work_package_id, :string)
    field(:superseded_reason, :string)
    field(:abandoned_rationale, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec outcomes() :: [String.t()]
  def outcomes, do: @outcomes

  @spec evidence_field_specs(String.t()) :: [evidence_field_spec()]
  def evidence_field_specs(outcome), do: Map.get(@evidence_contract, outcome, [])

  @spec validate_evidence(String.t(), map()) ::
          :ok | {:error, %{required(String.t()) => [String.t()]}}
  def validate_evidence(outcome, evidence) when is_map(evidence) do
    field_specs = evidence_field_specs(outcome)
    allowed_fields = Enum.map(field_specs, & &1.name)

    evidence_fields =
      evidence
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    supplied_fields =
      evidence
      |> Enum.reject(fn {_field, value} -> missing_evidence_value?(value) end)
      |> Enum.map(fn {field, _value} -> to_string(field) end)
      |> Enum.uniq()

    missing_fields =
      field_specs
      |> Enum.filter(& &1.required)
      |> Enum.map(& &1.name)
      |> Kernel.--(supplied_fields)

    unexpected_fields = evidence_fields -- allowed_fields

    if missing_fields == [] and unexpected_fields == [] do
      :ok
    else
      {:error,
       %{
         "missing_fields" => missing_fields,
         "unexpected_fields" => Enum.sort(unexpected_fields),
         "allowed_fields" => allowed_fields
       }}
    end
  end

  @spec terminal_status_for_outcome(String.t()) :: String.t() | nil
  def terminal_status_for_outcome("pr_merged"), do: "merged"
  def terminal_status_for_outcome("completed_no_pr"), do: "closed"
  def terminal_status_for_outcome("superseded"), do: "closed"
  def terminal_status_for_outcome("abandoned"), do: "abandoned"
  def terminal_status_for_outcome(_outcome), do: nil

  @spec terminal_status_matches_outcome?(String.t() | nil, String.t() | nil) :: boolean()
  def terminal_status_matches_outcome?("merged", "pr_merged"), do: true
  def terminal_status_matches_outcome?("merged_into_phase", "pr_merged"), do: true
  def terminal_status_matches_outcome?("closed", "completed_no_pr"), do: true
  def terminal_status_matches_outcome?("closed", "superseded"), do: true
  def terminal_status_matches_outcome?("abandoned", "abandoned"), do: true
  def terminal_status_matches_outcome?(_status, _outcome), do: false

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> trim_string_fields()
      |> put_new_value("id", stable_id())
      |> put_new_value("recorded_at", DateTime.utc_now(:microsecond))

    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :work_request_id,
      :work_package_id,
      :outcome,
      :idempotency_key,
      :recorded_by,
      :recorded_at,
      :pr_url,
      :pr_number,
      :pr_repository,
      :pr_merged_at,
      :merge_commit_sha,
      :no_pr_evidence,
      :successor_work_package_id,
      :superseded_reason,
      :abandoned_rationale
    ])
    |> validate_required([:id, :work_request_id, :work_package_id, :outcome, :idempotency_key, :recorded_at])
    |> validate_inclusion(:outcome, @outcomes)
    |> validate_number(:pr_number, greater_than: 0)
    |> validate_nonblank_optional(:recorded_by)
    |> validate_nonblank_optional(:pr_repository)
    |> validate_nonblank_optional(:merge_commit_sha)
    |> validate_outcome_evidence(attrs)
    |> validate_successor_is_different()
    |> unique_constraint(:id, name: :sympp_work_package_deliveries_id_unique_index)
    |> unique_constraint(:work_package_id,
      name: :sympp_work_package_deliveries_package_unique_index
    )
    |> foreign_key_constraint(:work_request_id)
    |> foreign_key_constraint(:work_package_id)
    |> foreign_key_constraint(:successor_work_package_id)
  end

  defp validate_outcome_evidence(changeset, attrs) do
    outcome = get_field(changeset, :outcome)
    evidence = Map.take(attrs, all_evidence_fields())

    case validate_evidence(outcome, evidence) do
      :ok ->
        changeset

      {:error, details} ->
        changeset
        |> add_evidence_errors(details["missing_fields"], "can't be blank", :required)
        |> add_evidence_errors(details["unexpected_fields"], "is not allowed for outcome", :exclusion)
    end
  end

  defp all_evidence_fields do
    @outcomes
    |> Enum.flat_map(fn outcome -> Enum.map(evidence_field_specs(outcome), & &1.name) end)
    |> Enum.uniq()
  end

  defp add_evidence_errors(changeset, fields, message, validation) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      add_error(changeset, String.to_existing_atom(field), message, validation: validation)
    end)
  end

  defp missing_evidence_value?(nil), do: true
  defp missing_evidence_value?(value) when is_binary(value), do: String.trim(value) == ""
  defp missing_evidence_value?(_value), do: false

  defp validate_successor_is_different(changeset) do
    work_package_id = get_field(changeset, :work_package_id)
    successor_id = get_field(changeset, :successor_work_package_id)

    if is_binary(work_package_id) and work_package_id == successor_id do
      add_error(changeset, :successor_work_package_id, "must be different from work_package_id")
    else
      changeset
    end
  end

  defp validate_nonblank_optional(changeset, field) do
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

  defp trim_string_fields(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(value) -> {key, String.trim(value)}
      entry -> entry
    end)
  end

  defp put_new_value(attrs, key, value) do
    if Map.get(attrs, key) in [nil, ""] do
      Map.put(attrs, key, value)
    else
      attrs
    end
  end

  defp stable_id do
    Id.random("wrsd")
  end
end
