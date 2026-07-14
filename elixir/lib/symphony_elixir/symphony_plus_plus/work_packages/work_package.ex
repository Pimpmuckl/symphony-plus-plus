defmodule SymphonyElixir.SymphonyPlusPlus.WorkPackages.WorkPackage do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.BranchPattern
  alias SymphonyElixir.SymphonyPlusPlus.Id
  alias SymphonyElixir.SymphonyPlusPlus.Policies.Templates
  alias SymphonyElixir.SymphonyPlusPlus.ReviewRequirement
  alias SymphonyElixir.SymphonyPlusPlus.WorkPackages.StringList

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @executable_kinds [
    "standard_pr",
    "quick_fix",
    "hotfix",
    "docs",
    "investigation",
    "adapter",
    "mcp",
    "skill",
    "hooks"
  ]
  @phase_child_kind "phase_child"
  @planned_slice_kinds @executable_kinds
  @anchor_kinds ["delegation"]
  @kinds @executable_kinds ++ [@phase_child_kind] ++ @anchor_kinds
  @legacy_kinds [
    "review_only",
    "setup",
    "core",
    "product",
    "dashboard",
    "integration",
    "security",
    "hardening",
    "pilot",
    "e2e",
    "analysis"
  ]
  @persisted_kinds @kinds ++ @legacy_kinds
  @legacy_ready_status "ready_for_human_merge"
  @ready_status "ready_for_merge"

  @statuses [
    "created",
    "ready_for_worker",
    "claimed",
    "planning",
    "implementing",
    "reviewing",
    "ci_waiting",
    @ready_status,
    "ready_for_architect_merge",
    "merging_into_phase",
    "merged_into_phase",
    "merged",
    "closed",
    "blocked",
    "abandoned"
  ]
  @persisted_statuses @statuses ++ [@legacy_ready_status]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          kind: String.t() | nil,
          title: String.t() | nil,
          repo: String.t() | nil,
          base_branch: String.t() | nil,
          branch_pattern: String.t() | nil,
          product_description: String.t() | nil,
          engineering_scope: String.t() | nil,
          allowed_file_globs: [String.t()] | nil,
          review_requirement: map() | nil,
          policy_template: String.t() | nil,
          acceptance_criteria: [String.t()] | nil,
          worktree_path: String.t() | nil,
          worktree_target_repo_root: String.t() | nil,
          status: String.t() | nil,
          parent_id: String.t() | nil,
          phase_id: String.t() | nil,
          owner_id: String.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_work_packages" do
    field(:kind, :string)
    field(:title, :string)
    field(:repo, :string)
    field(:base_branch, :string)
    field(:branch_pattern, :string)
    field(:product_description, :string)
    field(:engineering_scope, :string)
    field(:allowed_file_globs, StringList, default: [])
    field(:review_requirement, :map)
    field(:policy_template, :string)
    field(:acceptance_criteria, StringList, default: [])
    field(:worktree_path, :string)
    field(:worktree_target_repo_root, :string)
    field(:status, :string)
    field(:parent_id, :string)
    field(:phase_id, :string)
    field(:owner_id, :string)

    timestamps(type: :utc_datetime_usec)
  end

  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @spec executable_kinds() :: [String.t()]
  def executable_kinds, do: @executable_kinds

  @spec planned_slice_kinds() :: [String.t()]
  def planned_slice_kinds, do: @planned_slice_kinds

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @spec persisted_statuses() :: [String.t()]
  def persisted_statuses, do: @persisted_statuses

  @spec create_changeset(map()) :: Ecto.Changeset.t()
  def create_changeset(attrs) do
    attrs =
      attrs
      |> normalize_keys()
      |> put_new_value("id", stable_id())
      |> put_new_value("status", "created")

    %__MODULE__{}
    |> changeset(attrs)
    |> unique_constraint(:id, name: :sympp_work_packages_id_unique_index)
  end

  @spec update_changeset(t(), map()) :: Ecto.Changeset.t()
  def update_changeset(%__MODULE__{} = work_package, attrs) do
    attrs = Map.drop(normalize_keys(attrs), ["id", "inserted_at", "updated_at", "created_at"])

    work_package
    |> changeset(attrs, update_valid_kinds(work_package, attrs))
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = work_package, attrs) do
    changeset(work_package, attrs, @kinds)
  end

  defp changeset(%__MODULE__{} = work_package, attrs, valid_kinds) do
    attrs = attrs |> normalize_keys() |> normalize_status()

    work_package
    |> cast(attrs, [
      :id,
      :kind,
      :title,
      :repo,
      :base_branch,
      :branch_pattern,
      :product_description,
      :engineering_scope,
      :allowed_file_globs,
      :review_requirement,
      :policy_template,
      :acceptance_criteria,
      :worktree_path,
      :worktree_target_repo_root,
      :status,
      :parent_id,
      :phase_id,
      :owner_id
    ])
    |> validate_required([:id, :kind, :title, :repo, :base_branch, :acceptance_criteria, :status])
    |> validate_inclusion(:kind, valid_kinds)
    |> validate_inclusion(:status, valid_statuses(work_package))
    |> validate_branch_pattern()
    |> validate_policy_template()
    |> validate_review_requirement()
  end

  defp update_valid_kinds(%__MODULE__{} = work_package, attrs) do
    case Map.get(attrs, "kind") do
      nil -> @persisted_kinds
      kind when kind == work_package.kind -> @persisted_kinds
      _kind -> @kinds
    end
  end

  defp validate_branch_pattern(changeset) do
    validate_change(changeset, :branch_pattern, fn :branch_pattern, value ->
      case BranchPattern.validate(value) do
        :ok ->
          []

        {:error, reason} ->
          [branch_pattern: {BranchPattern.error_message(reason), validation: :branch_pattern, reason: reason}]
      end
    end)
  end

  defp validate_policy_template(changeset) do
    case get_field(changeset, :policy_template) do
      nil ->
        changeset

      policy_template ->
        kind = get_field(changeset, :kind)

        if canonical_policy_template?(kind, policy_template) do
          changeset
        else
          add_error(changeset, :policy_template, "is invalid", validation: :policy_template)
        end
    end
  end

  defp validate_review_requirement(changeset) do
    validate_change(changeset, :review_requirement, fn :review_requirement, requirement ->
      case ReviewRequirement.validation_error(requirement) do
        nil -> []
        message -> [review_requirement: message]
      end
    end)
  end

  defp canonical_policy_template?(kind, policy_template), do: Templates.compatible_kind?(kind, policy_template)

  defp valid_statuses(%__MODULE__{status: @legacy_ready_status}), do: @persisted_statuses
  defp valid_statuses(%__MODULE__{}), do: @statuses

  defp normalize_status(attrs) do
    case Map.fetch(attrs, "status") do
      {:ok, @legacy_ready_status} -> Map.put(attrs, "status", @ready_status)
      _status -> attrs
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
    Id.random("wp")
  end
end
