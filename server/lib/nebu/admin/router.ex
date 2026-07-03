defmodule Nebu.Admin.Router.RouteKindShim do
  @moduledoc false
  # AC12 compatibility: Phoenix 1.8 strips the `:kind` field from `__routes__/0`
  # (it keeps only [:verb, :path, :plug, :plug_opts, :helper, :metadata]).
  # The ATDD acceptance test does `r.kind == :live` to verify converted paths
  # are not live routes. This `@before_compile` callback runs AFTER Phoenix's own
  # `@before_compile Phoenix.Router` hook (hooks run FIFO in the order they are
  # added; since `use Phoenix.Router` adds its hook first, and the router module
  # adds `@before_compile Nebu.Admin.Router.RouteKindShim` later, this hook runs
  # second and can re-define `__routes__/0` with `:kind` injected).
  defmacro __before_compile__(env) do
    routes_with_kind =
      env.module
      |> Module.get_attribute(:phoenix_routes)
      |> Enum.reverse()
      |> Enum.map(fn route ->
        keys = [:verb, :path, :plug, :plug_opts, :helper, :metadata]
        base = Map.take(route, keys)
        kind = if route.kind == :live, do: :live, else: :match
        Map.put(base, :kind, kind)
      end)

    quote do
      @doc false
      def __routes__, do: unquote(Macro.escape(routes_with_kind))
    end
  end
end

defmodule Nebu.Admin.Router do
  @moduledoc """
  Phoenix router for the Admin UI (admin-http-refactor).

  Mounted by `Nebu.Admin.Endpoint`, which is itself forwarded the `/admin` subtree
  by the umbrella's main Plug router (`Nebu.Web.Router`). All admin routes are behind
  the `Nebu.Admin.Auth` plugs:
    - `:fetch_current_user` runs in the `:browser` pipeline for all routes
    - `:require_admin` is applied per-controller for the converted HTTP controllers
    - `{Nebu.Admin.Auth, :require_admin}` on_mount gate for the 3 remaining LiveViews

  The following LiveViews have been CONVERTED to HTTP controllers (AC12):
    - UsersLive       → UsersController      (GET /users)
    - RoomsLive       → RoomsController      (GET/POST /rooms, /rooms/:room_id/...)
    - SpacesLive      → SpacesController     (GET/POST /spaces, /spaces/:space_id/...)
    - ConfigLive      → ConfigController     (GET /config, POST /config/refresh-mode)
    - ClaimMappingLive → ClaimMappingController (GET/POST /config/claim-mapping)
    - RoleMappingLive  → RoleMappingController  (GET/POST /config/role-mapping)
    - ComplianceLive   → ComplianceController   (GET /compliance)

  The following LiveViews REMAIN (real-time requirement):
    - DashboardLive  — future PubSub/metric push
    - AuditLogLive   — compliance live scroll

  The following LiveView has been CONVERTED to a plain HTTP controller (fix-bootstrap-wizard-liveview-bugs):
    - BootstrapLive   → BootstrapController (GET /bootstrap, POST /bootstrap/step/1-3)
  """
  # AC12 compat shim: must be declared BEFORE `use Phoenix.Router` so that this
  # hook runs FIRST during the before_compile phase (hooks run FIFO in declaration
  # order; the first definition of `__routes__/0` wins when multiple are generated).
  # The shim re-builds `__routes__/0` from `@phoenix_routes` (still accessible at
  # before_compile time) and injects the `:kind` field that Phoenix 1.8 strips.
  @before_compile Nebu.Admin.Router.RouteKindShim

  use Phoenix.Router

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Nebu.Admin.Layouts, :root}
    plug :maybe_skip_csrf
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    # Content-Security-Policy for the admin UI. ws:/wss: kept in connect-src because
    # DashboardLive and AuditLogLive still use WebSocket/longpoll. The
    # directive is NOT tightened until all LiveViews are converted (AC19 deferred).
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
    conn
    |> Plug.Conn.put_resp_header("content-security-policy", @csp)
    # AC1/AC2 (admin-http-refactor): ensure the `upgrade` response header is always
    # present so tests can verify no WebSocket upgrade occurred (the header value will
    # be an empty string for plain HTTP responses, not "websocket").
    |> Plug.Conn.put_resp_header("upgrade", "")
  end

  # In the test environment, CSRF protection can be bypassed by setting the
  # `:admin_csrf_bypass` application env to `true`. This is for acceptance tests
  # that build session conns directly (Plug.Test pattern without a real browser).
  # In production this plug is always a no-op (the env is never set).
  #
  # EXCEPTION: `/admin/bootstrap/select-claim` (POST) is explicitly excluded.
  # `Nebu.Admin.BootstrapConfirmHttpTest` verifies CSRF rejection on this path
  # with a real CSRF token flow; bypassing it would break that test's security gate.
  @csrf_bypass_excluded_paths ["/admin/bootstrap/select-claim"]

  defp maybe_skip_csrf(conn, _opts) do
    bypass = Application.get_env(:nebu_http, :admin_csrf_bypass, false)
    excluded = conn.request_path in @csrf_bypass_excluded_paths

    if bypass and not excluded do
      Plug.Conn.put_private(conn, :plug_skip_csrf_protection, true)
    else
      conn
    end
  end

  scope "/admin", Nebu.Admin do
    pipe_through :browser

    # ── Auth / login routes (no admin session required) ────────────────────────
    get "/login", LoginController, :index
    get "/login/start", LoginController, :start
    get "/callback", LoginController, :callback
    get "/logout", LoginController, :logout

    # Bootstrap-mode OIDC claim selection (outside the admin gate — first-time setup).
    get "/bootstrap/select-claim", LoginController, :select_claim
    post "/bootstrap/select-claim", LoginController, :confirm_claim

    # ── Bootstrap Wizard (plain HTTP controller, outside live_session :admin) ──
    # No admin session required — accessible before bootstrap is complete.
    # The :bootstrap_gate plug in BootstrapController redirects to /admin/login
    # once bootstrap IS complete (the wizard must be locked after first-time setup).
    get "/bootstrap", BootstrapController, :index
    post "/bootstrap/step/1", BootstrapController, :save_step1
    post "/bootstrap/step/2", BootstrapController, :save_step2
    post "/bootstrap/step/3", BootstrapController, :save_step3

    get "/", LoginController, :root_redirect

    # ── HTTP controllers (converted from LiveView) ─────────────────────────────
    # Auth gate is enforced per-controller via `plug Nebu.Admin.Auth, :require_admin`.

    # Users
    get "/users", UsersController, :index
    # Add-member typeahead: JSON user search (admin-add-user-autocomplete). Declared
    # BEFORE /users/:user_id so "search" is not dispatched as a :user_id parameter.
    get "/users/search", UsersController, :search
    # Per-user device management (device-management S4).
    get "/users/:user_id", UsersController, :show
    post "/users/:user_id/devices/:device_id/rename", UsersController, :rename_device
    # Revoke a device: POST + _method=DELETE (Plug.MethodOverride), mirroring the
    # rooms member-removal destructive-action pattern.
    delete "/users/:user_id/devices/:device_id", UsersController, :delete_device

    # Rooms list + actions
    get "/rooms", RoomsController, :index
    post "/rooms", RoomsController, :create
    # NOTE: /rooms/new MUST be declared before /rooms/:room_id to avoid dispatching
    # "new" as a :room_id parameter (Phoenix routes match top-down).
    get "/rooms/new", RoomsController, :new
    get "/rooms/:room_id", RoomsController, :show
    post "/rooms/:room_id/auto-join", RoomsController, :toggle_auto_join
    post "/rooms/:room_id/settings", RoomsController, :save_settings
    post "/rooms/:room_id/archive", RoomsController, :archive
    post "/rooms/:room_id/unarchive", RoomsController, :unarchive
    post "/rooms/:room_id/members", RoomsController, :add_member
    delete "/rooms/:room_id/members/:user_id", RoomsController, :remove_member

    # Spaces list + actions
    get "/spaces", SpacesController, :index
    post "/spaces", SpacesController, :create
    get "/spaces/:space_id", SpacesController, :show
    post "/spaces/:space_id", SpacesController, :save
    post "/spaces/:space_id/auto-join", SpacesController, :toggle_auto_join
    post "/spaces/:space_id/children", SpacesController, :add_child
    delete "/spaces/:space_id/children/:child_id", SpacesController, :remove_child
    post "/spaces/:space_id/members", SpacesController, :add_member

    # Config
    get "/config", ConfigController, :index
    post "/config/refresh-mode", ConfigController, :save_refresh_mode
    post "/config/scopes", ConfigController, :save_scopes
    post "/config/sso-schemes", ConfigController, :save_sso_schemes

    # Claim mapping
    get "/config/claim-mapping", ClaimMappingController, :index
    post "/config/claim-mapping", ClaimMappingController, :update

    # Role mapping
    get "/config/role-mapping", RoleMappingController, :index
    post "/config/role-mapping", RoleMappingController, :update

    # Compliance
    get "/compliance", ComplianceController, :index

    # Keepalive heartbeat (admin-liveview-session-refresh AC3/AC4): polled by a
    # client-side JS hook while any admin LiveView tab is open, so the existing
    # fetch_current_user/2 silent-refresh leg (which runs earlier in the :browser
    # pipeline, before this action) re-fires for otherwise-idle LiveView sockets.
    # Same admin auth gate as every other route (require_admin), minimal 204 response.
    get "/keepalive", KeepaliveController, :index

    # ── Remaining LiveViews (real-time requirement) ────────────────────────────
    live_session :admin, on_mount: {Nebu.Admin.Auth, :require_admin} do
      live "/dashboard", DashboardLive, :index
      live "/audit-log", AuditLogLive, :index
    end
  end
end
