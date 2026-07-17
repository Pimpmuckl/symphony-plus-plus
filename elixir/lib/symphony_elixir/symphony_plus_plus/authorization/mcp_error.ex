defmodule SymphonyElixir.SymphonyPlusPlus.Authorization.MCPError do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.Authorization.Decision
  alias SymphonyElixir.SymphonyPlusPlus.Planning.Redactor

  @authorization_code -32_003
  @precondition_code -32_009
  @lifecycle_code -32_010

  @spec from_decision(Decision.t(), String.t()) :: :ok | {:error, integer(), String.t(), map()}
  def from_decision(%Decision{allowed?: true}, _resource), do: :ok

  def from_decision(%Decision{} = decision, resource) when is_binary(resource) do
    {code, message} = code_and_message(decision)

    {:error, code, message,
     %{
       "resource" => resource,
       "reason" => decision.legacy_reason || decision.reason_code,
       "reason_code" => decision.reason_code,
       "decision_reason" => Atom.to_string(decision.reason),
       "action" => Atom.to_string(decision.action),
       "target" => target_payload(decision)
     }
     |> maybe_put("legacy_reason", decision.legacy_reason)
     |> maybe_put("requirements", decision.requirements)
     |> maybe_put("redactions", decision.redactions)
     |> Redactor.redact_output()}
  end

  defp code_and_message(%Decision{reason: :authorization_denied}), do: {@authorization_code, "Forbidden"}
  defp code_and_message(%Decision{reason: :precondition_denied}), do: {@precondition_code, "Precondition Failed"}
  defp code_and_message(%Decision{reason: :lifecycle_denied}), do: {@lifecycle_code, "Lifecycle Denied"}

  defp target_payload(%Decision{target: target}) do
    %{
      "type" => Atom.to_string(target.type),
      "id" => target.id,
      "phase_id" => target.phase_id,
      "work_request_id" => target.work_request_id,
      "work_package_id" => target.work_package_id
    }
  end

  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
