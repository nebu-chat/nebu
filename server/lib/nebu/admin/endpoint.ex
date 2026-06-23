defmodule Nebu.Admin.Endpoint do
  @moduledoc """
  Phoenix.Endpoint for the LiveView Admin UI (admin-ui-migration).

  This endpoint is NOT a second front-door listener. The umbrella keeps its single
  Bandit listener (started in `Nebu.Web.Application` with `Nebu.Web.Router`) serving
  Matrix/media. The main Plug router *forwards* the `/admin` subtree into this
  endpoint via `Nebu.Admin.Endpoint.call/2` (see `Nebu.Web.Router`), so admin
  requests ride the same Bandit listener and port (`server: false` — this endpoint
  never opens its own socket).

  The LiveView statefull socket (`/admin/live`) is declared here; the DOM-diff
  websocket connects after the initial static render so the auto-join toggle updates
  in place without a full reload (AC2).
  """
  use Phoenix.Endpoint, otp_app: :nebu

  # Cookie-session options shared by the socket transport and the router's
  # fetch_session. Signing uses the endpoint secret_key_base + this salt.
  # F-2 (security review): http_only blocks JS cookie theft; secure pins the admin
  # session to TLS.
  #
  # `secure` is read at RUNTIME (not compile_env) so the SAME prod release can serve
  # the local docker-compose dev stack over plain HTTP: a compile-baked `secure:true`
  # made the login-state cookie un-sendable over http://localhost on stricter browsers
  # (Safari/curl) → "Invalid login state" on the OIDC callback. Defaults to true so
  # production is fail-closed; the dev compose sets NEBU_ADMIN_SESSION_SECURE=false.
  # The flag only affects SETTING the cookie (Plug.Session below); reading it (socket /
  # fetch_session) is unaffected, so the socket keeps the static option list.
  @session_options [
    store: :cookie,
    key: "_nebu_admin_key",
    signing_salt: "nebu-admin-session",
    same_site: "Lax",
    http_only: true
  ]

  @doc "Session options for reading the admin session (socket / fetch_session)."
  def session_options, do: @session_options

  @doc "Session options for SETTING the admin session cookie (runtime `secure`)."
  def runtime_session_options do
    Keyword.put(
      @session_options,
      :secure,
      Application.get_env(:nebu_http, :admin_session_secure, true)
    )
  end

  socket "/admin/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  # Static assets (vendored phoenix*.js + app.css) served under /admin/static.
  # No npm/esbuild build step — assets are plain files in priv/static.
  plug Plug.Static,
    at: "/admin/static",
    from: :nebu,
    gzip: false,
    only: ~w(assets fonts images favicon.ico)

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:nebu_http, :admin_endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  # Runtime session options (see runtime_session_options/0) so `secure` follows the
  # deployment scheme instead of being baked at compile time.
  plug :admin_session
  plug Nebu.Admin.Router

  def admin_session(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(runtime_session_options()))
  end
end
