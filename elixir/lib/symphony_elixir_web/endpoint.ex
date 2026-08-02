defmodule SymphonyElixirWeb.Endpoint do
  @moduledoc """
  Phoenix endpoint for Symphony's optional observability UI and API.
  """

  use Phoenix.Endpoint, otp_app: :symphony_elixir

  @session_options [
    store: :cookie,
    key: "_symphony_elixir_key",
    signing_salt: "symphony-session"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [
      check_origin: :conn,
      check_csrf: true,
      connect_info: [:peer_data, :uri, :x_headers, session: @session_options]
    ],
    longpoll: false
  )

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(SymphonyElixirWeb.MCPHTTPPlug)

  plug(Plug.Static,
    at: "/",
    from: {:symphony_elixir, "priv/static"},
    only: ~w(assets),
    cache_control_for_etags: "public, max-age=31536000, immutable"
  )

  plug(Plug.Static,
    at: "/",
    from: {:symphony_elixir, "priv/static"},
    only: ~w(favicon.ico splusplus-logo.png)
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(SymphonyElixirWeb.Router)
end
