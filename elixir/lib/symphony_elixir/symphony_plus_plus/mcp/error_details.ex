defmodule SymphonyElixir.SymphonyPlusPlus.MCP.ErrorDetails do
  @moduledoc false

  alias SymphonyElixir.SymphonyPlusPlus.ReviewProfiles

  @spec invalid_params_error(String.t(), term()) :: {:error, integer(), String.t(), map()}
  def invalid_params_error(tool, {:invalid_enum, field, allowed_values}) do
    field = to_string(field)

    {:error, -32_602, "Invalid params",
     %{
       "tool" => tool,
       "reason" => "invalid_#{field}",
       "validation_errors" => [
         %{
           "field" => field,
           "reason" => "invalid_value",
           "allowed_values" => Enum.map(allowed_values, &reason_text/1)
         }
       ]
     }}
  end

  def invalid_params_error(tool, reason) do
    {:error, -32_602, "Invalid params", %{"tool" => tool, "reason" => reason_text(reason)}}
  end

  @spec changeset_invalid_params_error(String.t(), term(), Ecto.Changeset.t()) :: {:error, integer(), String.t(), map()}
  def changeset_invalid_params_error(tool, reason, %Ecto.Changeset{} = changeset) do
    data =
      case changeset_validation_errors(changeset) do
        [] -> %{"tool" => tool, "reason" => reason_text(reason)}
        errors -> %{"tool" => tool, "reason" => reason_text(reason), "validation_errors" => errors}
      end

    {:error, -32_602, "Invalid params", data}
  end

  defp changeset_validation_errors(%Ecto.Changeset{errors: errors}) do
    Enum.map(errors, fn {field, error} -> changeset_validation_error(field, error) end)
  end

  defp changeset_validation_error(field, {message, opts}) do
    field = Atom.to_string(field)

    %{
      "field" => field,
      "message" => changeset_validation_message(field, message, opts),
      "reason" => changeset_validation_reason(field, opts)
    }
    |> maybe_put_allowed_values(field, opts)
  end

  defp changeset_validation_message("review_lanes", _message, _opts) do
    "must be Review Suite profiles only; GitHub review lanes do not belong here"
  end

  defp changeset_validation_message(_field, message, opts) do
    Regex.replace(~r/%{(count|number)}/, message, fn _match, key ->
      opts
      |> Keyword.get(changeset_message_key(key))
      |> to_string()
    end)
  end

  defp changeset_message_key("count"), do: :count
  defp changeset_message_key("number"), do: :number

  defp changeset_validation_reason("review_lanes", _opts), do: "invalid_review_lanes"

  defp changeset_validation_reason(_field, opts) do
    case Keyword.get(opts, :validation) do
      :required -> "required"
      :inclusion -> "invalid_value"
      :number -> "invalid_number"
      validation when is_atom(validation) -> Atom.to_string(validation)
      _validation -> "invalid"
    end
  end

  defp maybe_put_allowed_values(detail, "review_lanes", _opts) do
    Map.put(detail, "allowed_values", ReviewProfiles.review_suite_profiles())
  end

  defp maybe_put_allowed_values(detail, _field, opts) do
    case Keyword.get(opts, :enum) do
      values when is_list(values) -> Map.put(detail, "allowed_values", Enum.map(values, &reason_text/1))
      _values -> detail
    end
  end

  defp reason_text(reason) when is_binary(reason), do: reason
  defp reason_text(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_text(reason), do: inspect(reason)
end
