defmodule Nebu.Admin.Router do
  @moduledoc """
  Phoenix router for the LiveView Admin UI (admin-ui-migration).

  Mounted by `Nebu.Admin.Endpoint`, which is itself forwarded the `/admin` subtree
  by the umbrella's main Plug router (`Nebu.Web.Router`). All live routes sit behind the
  `{Nebu.Admin.Auth, :require_admin}` on_mount gate (AC3): a non-admin (or
  unauthenticated) operator is redirected to `/admin/login`.

    GET  /admin            → redirect to /admin/rooms
    LIVE /admin/rooms      → RoomsLive   (AC1, AC2)
    LIVE /admin/rooms/:id  → RoomsLive   (Go parity: master-detail deep link)
    LIVE /admin/users      → UsersLive   (AC1)
    LIVE /admin/bootstrap  → BootstrapLive (AC6)
    GET  /admin/login      → login page (AC3 redirect target)
  """
  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Nebu.Admin.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # MINOR-4: Content-Security-Policy for the admin UI. Vendored (non-inline) JS is
    # served same-origin from /admin/static, so script-src is 'self' (no
    # 'unsafe-inline'/'unsafe-eval'). The LiveView DOM-diff websocket connects to
    # /admin/live, so connect-src allows ws:/wss: same-origin. style-src keeps
    # 'unsafe-inline' for DaisyUI/inline styles; img-src allows data: URIs.
    plug :admin_csp
    plug Nebu.Admin.Auth, :fetch_current_user
  end

  @csp "default-src 'self'; " <>
         "connect-src 'self' ws: wss:; " <>
         "img-src 'self' data:; " <>
         "style-src 'self' 'unsafe-inline'; " <>
         "script-src 'self'; " <>
         "base-uri 'self'; " <>
         "frame-ancestors 'self'"

  defp admin_csp(conn, _opts) do
    Plug.Conn.put_resp_header(conn, "content-security-policy", @csp)
  end

  scope "/admin", Nebu.Admin do
    pipe_through :browser

    get "/login", LoginController, :index
    # go-removal-cleanup: the full OIDC Authorization-Code + PKCE login is now served
    # in Elixir (Nebu.Admin.Auth). login/start generates PKCE+state+nonce and
    # redirects to the IdP; callback exchanges the code, verifies the ID token, enforces
    # the admin-group claim, and mints the Phoenix admin session; logout clears it.
    get "/login/start", LoginController, :start
    get "/callback", LoginController, :callback
    get "/logout", LoginController, :logout

    # Bootstrap-mode OIDC claim selection (Go parity: GET/POST /admin/bootstrap/select-claim).
    # These are plain controller routes OUTSIDE the live_session admin gate so the first
    # operator can reach them WITHOUT an admin session while bootstrap is incomplete. AC5:
    # the handlers themselves re-check bootstrap_completed?() and become inert once setup
    # is done (refuse + redirect to /admin/login) — mirroring the on_mount gate logic.
    get "/bootstrap/select-claim", LoginController, :select_claim
    post "/bootstrap/select-claim", LoginController, :confirm_claim

    get "/", LoginController, :root_redirect

    live_session :admin, on_mount: {Nebu.Admin.Auth, :require_admin} do
      live "/dashboard", DashboardLive, :index
      live "/rooms", RoomsLive, :index
      live "/rooms/:room_id", RoomsLive, :detail
      live "/spaces", SpacesLive, :index
      live "/spaces/:space_id", SpacesLive, :detail
      live "/users", UsersLive, :index
      live "/compliance", ComplianceLive, :index
      live "/audit-log", AuditLogLive, :index
      live "/config", ConfigLive, :index
      live "/config/claim-mapping", ClaimMappingLive, :index
      live "/config/role-mapping", RoleMappingLive, :index
      live "/bootstrap", BootstrapLive, :index
    end
  end
end
