defmodule SymphonyElixir.SymphonyPlusPlus.OperatorAudit do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Changeset

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Target
  alias SymphonyElixir.SymphonyPlusPlus.Id
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor

  @primary_key {:id, :string, autogenerate: false}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          actor_id: String.t() | nil,
          actor_role: String.t() | nil,
          actor_source: String.t() | nil,
          action: String.t() | nil,
          target_type: String.t() | nil,
          target_id: String.t() | nil,
          target_work_request_id: String.t() | nil,
          target_work_package_id: String.t() | nil,
          decision: String.t() | nil,
          reason: String.t() | nil,
          request_metadata: map(),
          tool_metadata: map(),
          created_at: DateTime.t() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "sympp_operator_audit_events" do
    field(:actor_id, :string)
    field(:actor_role, :string)
    field(:actor_source, :string)
    field(:action, :string)
    field(:target_type, :string)
    field(:target_id, :string)
    field(:target_work_request_id, :string)
    field(:target_work_package_id, :string)
    field(:decision, :string)
    field(:reason, :string)
    field(:request_metadata, :map, default: %{})
    field(:tool_metadata, :map, default: %{})
    field(:created_at, :utc_datetime_usec)

    timestamps(type: :utc_datetime_usec)
  end

  @spec append(module(), atom(), Target.t(), map(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def append(repo, action, %Target{} = target, request_metadata, tool_metadata)
      when is_atom(repo) and is_atom(action) and is_map(request_metadata) and is_map(tool_metadata) do
    repo.insert(changeset(action, target, request_metadata, tool_metadata))
  end

  defp changeset(action, target, request_metadata, tool_metadata) do
    attrs =
      action
      |> attrs(target)
      |> attrs(request_metadata, tool_metadata)
      |> redact_attrs()

    %__MODULE__{}
    |> cast(attrs, [
      :id,
      :actor_id,
      :actor_role,
      :actor_source,
      :action,
      :target_type,
      :target_id,
      :target_work_request_id,
      :target_work_package_id,
      :decision,
      :reason,
      :request_metadata,
      :tool_metadata,
      :created_at
    ])
    |> validate_required([
      :id,
      :actor_id,
      :actor_role,
      :action,
      :target_type,
      :decision,
      :reason,
      :request_metadata,
      :tool_metadata,
      :created_at
    ])
  end

  defp attrs(action, %Target{} = target) do
    %{
      "id" => stable_id(),
      "actor_id" => "local-operator",
      "actor_role" => "human_operator",
      "actor_source" => "local_operator",
      "action" => Atom.to_string(action),
      "target_type" => Atom.to_string(target.type),
      "target_id" => target.id,
      "target_work_request_id" => target.work_request_id,
      "target_work_package_id" => target.work_package_id,
      "decision" => "not_applicable",
      "reason" => "trusted_local_human"
    }
  end

  defp attrs(attrs, request_metadata, tool_metadata) do
    Map.merge(attrs, %{
      "request_metadata" => request_metadata,
      "tool_metadata" => tool_metadata,
      "created_at" => DateTime.utc_now(:microsecond)
    })
  end

  defp redact_attrs(attrs) do
    attrs
    |> Map.update("actor_id", nil, &Redactor.redact_text/1)
    |> Map.update("actor_source", nil, &Redactor.redact_text/1)
    |> Map.update("target_id", nil, &Redactor.redact_text/1)
    |> Map.update("target_work_request_id", nil, &Redactor.redact_text/1)
    |> Map.update("target_work_package_id", nil, &Redactor.redact_text/1)
    |> Map.update("request_metadata", %{}, &redact_map/1)
    |> Map.update("tool_metadata", %{}, &redact_map/1)
  end

  defp redact_map(value) when is_map(value) do
    value
    |> Redactor.redact_output()
    |> Redactor.json_safe()
  end

  defp redact_map(_value), do: %{}

  defp stable_id do
    Id.random("opa")
  end
end
