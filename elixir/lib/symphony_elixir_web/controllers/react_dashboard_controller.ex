defmodule SymphonyElixirWeb.ReactDashboardController do
  @moduledoc """
  Bridges human-facing UI routes to the Vite-served React dashboard.
  """

  use Phoenix.Controller, formats: [:html]

  alias Plug.Conn
  @spec index(Conn.t(), map()) :: Conn.t()
  def index(conn, _params) do
    serve_dashboard_shell(conn)
  end

  defp serve_dashboard_shell(conn) do
    case dashboard_origin() do
      {:ok, origin} -> redirect(conn, external: dashboard_url(conn, origin))
      :error -> serve_built_dashboard_shell(conn)
    end
  end

  defp serve_built_dashboard_shell(conn) do
    case File.read(index_path()) do
      {:ok, body} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, prepare_dashboard_shell(conn, body))

      {:error, _reason} ->
        conn
        |> put_status(503)
        |> html("""
        <!doctype html>
        <html lang="en">
          <head><meta charset="utf-8"><title>Symphony++ Dashboard</title></head>
          <body><main id="root">Dashboard assets have not been built yet.</main></body>
        </html>
        """)
    end
  end

  defp index_path do
    :symphony_elixir
    |> :code.priv_dir()
    |> Path.join("static/index.html")
  end

  defp prepare_dashboard_shell(conn, body) do
    conn
    |> prefix_dashboard_assets(body)
    |> inject_dashboard_config(conn)
  end

  defp prefix_dashboard_assets(conn, body) do
    case script_name_prefix(conn) do
      "" ->
        body

      prefix ->
        body
        |> String.replace(~s(href="/), ~s(href="#{prefix}/))
        |> String.replace(~s(src="/), ~s(src="#{prefix}/))
    end
  end

  defp inject_dashboard_config(body, conn) do
    config =
      %{
        "apiBase" => prefixed_path(conn, "/api/v1/sympp/operator"),
        "basePath" => script_name_prefix(conn),
        "logoUrl" => prefixed_path(conn, "/splusplus-logo.png")
      }

    script = ~s(<script>window.SYMPP_DASHBOARD_CONFIG = #{Jason.encode!(config)};</script>)

    String.replace(body, "</head>", "    #{script}\n  </head>", global: false)
  end

  defp prefixed_path(%Conn{} = conn, path) when is_binary(path) do
    case script_name_prefix(conn) do
      "" -> path
      prefix -> prefix <> "/" <> String.trim_leading(path, "/")
    end
  end

  defp script_name_prefix(%Conn{script_name: []}), do: ""
  defp script_name_prefix(%Conn{script_name: script_name}), do: "/" <> Enum.join(script_name, "/")

  defp dashboard_origin do
    :symphony_elixir
    |> Application.get_env(SymphonyElixirWeb.Endpoint, [])
    |> Keyword.get(:sympp_dashboard_origin)
    |> normalize_dashboard_origin()
  end

  defp normalize_dashboard_origin(origin) when is_binary(origin) do
    case String.trim(origin) do
      "" -> :error
      value -> {:ok, String.trim_trailing(value, "/")}
    end
  end

  defp normalize_dashboard_origin(_origin), do: :error

  defp dashboard_url(conn, origin) do
    query = if conn.query_string == "", do: "", else: "?#{conn.query_string}"
    "#{origin}#{conn.request_path}#{query}"
  end
end
