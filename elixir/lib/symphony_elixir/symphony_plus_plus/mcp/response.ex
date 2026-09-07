defmodule SymphonyElixir.SymphonyPlusPlus.MCP.Response do
  @moduledoc false

  @spec response(term(), term()) :: map()
  def response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  @spec error(term(), integer(), String.t(), term()) :: map()
  def error(id, code, message, data) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message, "data" => data}}
  end

  @spec json_resource(String.t(), term()) :: map()
  def json_resource(uri, payload) do
    %{
      "contents" => [
        %{
          "uri" => uri,
          "mimeType" => "application/json",
          "text" => Jason.encode!(payload)
        }
      ]
    }
  end

  @spec text_resource(String.t(), String.t(), String.t()) :: map()
  def text_resource(uri, text, mime_type) do
    %{
      "contents" => [
        %{
          "uri" => uri,
          "mimeType" => mime_type,
          "text" => text
        }
      ]
    }
  end
end
