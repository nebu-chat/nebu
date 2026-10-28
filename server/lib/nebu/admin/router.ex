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

  Added later as plain HTTP controllers (no LiveView):
    - OAuthRegistrationsController (GET /oauth/registrations, GET|POST .../:client_id/approve, POST .../:client_id/reject)
    - OAuthClientsController (GET /oauth/clients[/revoked], GET|POST /oauth/clients/:client_id/revoke)

  The following LiveViews REMAIN (real-time requirement):
    - DashboardLive  — future PubSub/metric push
    - AuditLogLive   — compliance live scroll
    - LogsLive       — operational log Trace Map + live request-stream (enhanced-logging/admin-logs-monitoring-view)

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
    plug :accepts_formats
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

  # HTML for every admin route. The OAuth registration list additionally answers
  # `Accept: application/json` (story oauth-metadata-dcr-admin-approval, "JSON API" of the admin
  # list); no other admin route changes its accepted formats.
  @json_paths ["/admin/oauth/registrations"]

  defp accepts_formats(conn, _opts) do
    formats = if conn.request_path in @json_paths, do: ["html", "json"], else: ["html"]
    Phoenix.Controller.accepts(conn, formats)
  end

  # The admin policy; the OAuth approval pages replace `frame-ancestors 'self'` by `'none'` (see admin_csp/2).
  @csp "default-src 'self'; " <>
         "connect-src 'self' ws: wss:; " <>
         "img-src 'self' data:; " <>
         "style-src 'self' 'unsafe-inline'; " <>
         "script-src 'self'; " <>
         "base-uri 'self'; " <>
         "frame-ancestors 'self'"

  # NOTE: the OAuth registration list keeps this strict `img-src 'self' data:` by default (a
  # client's logo_uri is attacker-chosen; loading it would leak the admin's IP/UA). Only a
  # `?logos=1` request widens `img-src` for ITS OWN response, to the exact logo origins on that
  # page — see Nebu.Admin.OAuthRegistrationsController ("Logos only on click", ADR-033).

  # story oauth-client-revocation SO6: nothing under /admin/oauth/ may be framed (a hidden iframe of the approve or
  # revoke form is the clickjacking vector): `frame-ancestors 'none'`, `X-Frame-Options: DENY` and `Cache-Control: no-store` for those
  # responses; every other admin page keeps `'self'`. The per-response `img-src` widening of the logo mode works on
  # this value (it replaces only the `img-src` part).
  #
  # story sso-origins-admin-hardening (X-1): the same for the page `/admin/config` and the POSTs of its forms (the
  # `ConfigController` routes): the page carries the forms that widen legacy-SSO trust, a hidden iframe of it is the same
  # clickjacking vector. (Since story admin-config-privileged-forms-sweep the claim / role mapping pages are unframed too.)
  #
  # Decided on `conn.path_info` (the segment list the routing uses; empty segments are already dropped), NOT on
  # `request_path`: `/admin/config/`, `/admin//config` or `/admin/oauth//registrations` reach the same actions and must
  # get the same headers (review cycle 1, Kassandra Y-1).
  @config_unframed_segments ["refresh-mode", "scopes", "sso-schemes", "sso-origins", "oauth-switch", "claim-mapping", "role-mapping"]

  defp unframed_path?(["admin", "oauth" | _]), do: true
  defp unframed_path?(["admin", "config"]), do: true
  # story admin-forms-gate-sweep: the media settings page holds the marker forms of the media policy and the storage target (and the test connection)
  defp unframed_path?(["admin", "media", "settings" | _]), do: true
  defp unframed_path?(["admin", "config", segment]) when segment in @config_unframed_segments, do: true
  defp unframed_path?(_path_info), do: false

  defp admin_csp(conn, _opts) do
    conn
    |> then(fn conn ->
      if unframed_path?(conn.path_info) do
        conn
        |> Plug.Conn.put_resp_header("content-security-policy", String.replace(@csp, "frame-ancestors 'self'", "frame-ancestors 'none'"))
        |> Plug.Conn.put_resp_header("x-frame-options", "DENY")
        # confirm pages carry a CSRF token, client data and the re-authentication state; the 403 page too (Kassandra L-1)
        |> Plug.Conn.put_resp_header("cache-control", "no-store")
      else
        Plug.Conn.put_resp_header(conn, "content-security-policy", @csp)
      end
    end)
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
    post "/config/sso-origins", ConfigController, :save_sso_origins
    post "/config/oauth-switch", ConfigController, :save_oauth_switch

    # Logs configuration (enhanced-logging/admin-logs-retention-settings)
    get "/logs/config", LogsController, :index
    post "/logs/config/retention", LogsController, :save_retention

    # Media policy settings (media-security-admin-control/9b-media-settings-ui)
    get "/media/settings", MediaSettingsController, :index
    post "/media/settings", MediaSettingsController, :save
    # Storage-target config + Test Connection (media-security-admin-control/
    # 11b-storage-ui-test-connection) — extends the SAME page/controller
    # above with a second, independent form section; no new route/nav item.
    post "/media/settings/storage", MediaSettingsController, :save_storage
    post "/media/settings/storage/test-connection", MediaSettingsController, :test_connection

    # Claim mapping
    get "/config/claim-mapping", ClaimMappingController, :index
    post "/config/claim-mapping", ClaimMappingController, :update

    # Role mapping
    get "/config/role-mapping", RoleMappingController, :index
    post "/config/role-mapping", RoleMappingController, :update

    # Compliance
    get "/compliance", ComplianceController, :index

    # OAuth client registrations (epic oauth-broker / oauth-metadata-dcr-admin-approval, AC4):
    # list pending Dynamic-Client-Registration requests, approve or reject them (Post-Redirect-Get).
    get "/oauth/registrations", OAuthRegistrationsController, :index
    # Bulk removal of PENDING registrations (story oauth-dcr-abuse-hardening, AH8/AH9): GET = read
    # only preview with a snapshot, POST = the removal (CSRF, one audit row). Above the
    # `:client_id` routes so "bulk-remove" can never be read as a client id.
    get "/oauth/registrations/bulk-remove", OAuthRegistrationsController, :bulk_preview
    post "/oauth/registrations/bulk-remove", OAuthRegistrationsController, :bulk_remove
    # Approve: a confirm PAGE (GET, read only) and the POST behind it (story oauth-client-revocation, SO3).
    get "/oauth/registrations/:client_id/approve", OAuthRegistrationsController, :approve_confirm
    post "/oauth/registrations/:client_id/approve", OAuthRegistrationsController, :approve
    post "/oauth/registrations/:client_id/reject", OAuthRegistrationsController, :reject

    # Approved / revoked clients and the revocation of an approved one (story oauth-client-revocation, CR7).
    # `/clients/revoked` is declared BEFORE the `:client_id` routes so "revoked" can never be read as a client id.
    get "/oauth/clients", OAuthClientsController, :index
    get "/oauth/clients/revoked", OAuthClientsController, :revoked
    get "/oauth/clients/:client_id/revoke", OAuthClientsController, :revoke_confirm
    post "/oauth/clients/:client_id/revoke", OAuthClientsController, :revoke

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
      # enhanced-logging/admin-logs-monitoring-view: live request-stream,
      # subscribed to the operational-log-store's PubSub topic. The embedded
      # Trace Map's Endpoint dimension was retired from this page by
      # enhanced-logging/trace-map-leitstand (AC13) in favor of the dedicated
      # radial-map page below.
      live "/logs", LogsLive, :index
      # enhanced-logging/trace-map-leitstand (AC1): the dedicated Trace Map
      # "Leitstand" page — a SEPARATE LiveView module (it defines
      # handle_params/3 for URL-driven filter state, which the shared
      # LogsLive must never export; see LogsLive.TraceMap's moduledoc).
      live "/logs/trace-map", LogsLive.TraceMap, :index
      # enhanced-logging/war-room-dedicated-page (amendment 1): repoints the
      # former stub (which rendered the Live Stream page, mislabeled) to the
      # real dedicated War Room page — a SEPARATE LiveView module (mirrors
      # LogsLive.TraceMap's own "one module, two router actions" shape),
      # room_id arriving as a static path segment for :show (no
      # handle_params/3 needed — see that module's moduledoc).
      live "/logs/war-room", LogsLive.WarRoom, :index
      live "/logs/war-room/:room_id", LogsLive.WarRoom, :show
      # media-security-admin-control/5a-admin-media-table: read-only, filterable,
      # keyset-paginated media_files overview. URL-driven filter/pagination state
      # (handle_params/3 + push_patch/2), same contract as LogsLive.TraceMap.
      live "/media", MediaLive, :index
      # media-security-admin-control/10a-scan-stats-rollup: Scan Health & Alerts
      # Dashboard — reads only the media_scan_stats rollup table, never a live
      # query over media_state_transitions' full history. MUST be declared
      # BEFORE "/media/:media_id" below (Phoenix routes match top-down; a
      # "health" segment would otherwise be dispatched as :media_id), same
      # NOTE as the "/rooms/new" vs "/rooms/:room_id" ordering above.
      live "/media/health", MediaHealthLive, :index
      # media-security-admin-control/6b-file-detail-storage-summary: read-only
      # per-file detail view reached from a row in the table above. `media_id`
      # is a static path segment (no handle_params/3 needed), same contract as
      # LogsLive.WarRoom's :show action.
      live "/media/:media_id", MediaLive.Detail, :show
    end
  end
end
