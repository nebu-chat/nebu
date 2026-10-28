defmodule Nebu.Web.Router do
  use Plug.Router

  # Order matters:
  # 1. RequestId assigns x-request-id (RequestLogger depends on it — see MINOR-3).
  # 2. RequestLogger registers its before_send callback BEFORE CORSPlug, so that
  #    even preflight OPTIONS requests (which CORSPlug halts with 204) are logged (AC3).
  # 3. CORSPlug handles preflight and sets CORS headers.
  # 4. Plug.Parsers runs before :match so body-reading routes work conventionally (MINOR-1).
  #    matrix-api-migration: a malformed-JSON body on POST /login must surface
  #    400 M_NOT_JSON rather than a 500-class Plug.Parsers.ParseError, so the
  #    parser is wrapped with a custom error handler that catches the parse error.
  plug Nebu.Web.Plugs.RequestId
  # 1b. ClientIP resolves the client address ONCE (CIDR-gated forwarding header, story
  #    oauth-trusted-proxy-client-ip) into conn.private; every per-IP consumer reads it through
  #    Nebu.Web.ClientIP.get/1. It must run before everything that keys on the client address.
  plug Nebu.Web.Plugs.ClientIP
  plug Nebu.Web.Plugs.RequestLogger
  plug :security_headers
  # CORSPlug with its defaults (credentials: true) everywhere EXCEPT the four OAuth browser-client
  # endpoints of stories oauth-token-endpoint / oauth-token-revocation-logout (T32 / R14 / oracle C15):
  # /oauth2/token, /oauth2/jwks, /oauth2/revoke and
  # /.well-known/openid-configuration answer `Access-Control-Allow-Origin: *` and must NEVER add
  # `Access-Control-Allow-Credentials` (responses AND their preflights). The global CORS behaviour of
  # every other path is unchanged.
  plug :cors
  # JsonBody runs Plug.Parsers but turns a malformed body into a tagged conn
  # (json_parse_error) instead of a raised 500 — so POST /login can answer
  # 400 M_NOT_JSON. It also enforces a 1 MB body-size cap (SEC directive).
  plug Nebu.Web.Plugs.JsonBody
  plug :match
  plug :dispatch

  # /health is UNPROTECTED — no Bearer token required (AC6).
  get "/health" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{status: "ok"}))
  end

  # /info — build metadata (Story 11-9), served by the single Bandit listener.
  # (Previously a separate gen_tcp Nebu.Health.Server tried to own port 4000 for
  # /health + /info, but it always lost the port race to Bandit and crash-looped;
  # the otp-consolidation single supervisor made that conflict fatal, so /info now
  # lives here on the one listener — see grpc-legacy-removal / ADR-019.)
  get "/info" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Nebu.BuildInfo.get()))
  end

  # ── UNAUTHENTICATED Matrix routes (matrix-api-migration) ──────────────────
  #
  # These mirror the Go gateway endpoints that require NO Bearer token:
  #   * POST /_matrix/client/v3/login            (authentication attempt itself)
  #   * GET  /_matrix/client/v3/profile/{userId} (public profile read)
  #   * GET  /_matrix/client/{v1,unstable}/auth_issuer, unstable auth_metadata (MSC2965): Nebu's own
  #     issuer/document while OAuth is enabled, the IdP passthrough while it is disabled
  #     (Nebu.Web.Plugs.OAuthDiscovery); the stable v1 auth_metadata is Nebu's own OAuth metadata
  #
  # They are forwarded to Nebu.Matrix.HttpPublic, which does NOT run OidcPlug, so
  # they must be matched BEFORE the catch-all "/_matrix" forward to Protected.
  # Plug.Router matches routes top-to-bottom, so prefix ordering is load-bearing.
  forward "/_matrix/client/v3/login", to: Nebu.Matrix.HttpPublic, init_opts: [action: :login]

  # oidc-session-refresh: POST /_matrix/client/v3/refresh (Matrix CS API v1.3) MUST
  # be reachable WITHOUT an Authorization header (the client refreshes precisely
  # when its access token is dead). Forward it to Nebu.Matrix.HttpPublic — which
  # does NOT run OidcPlug — BEFORE the catch-all "/_matrix" forward to Protected.
  # Plug.Router matches top-down, so this ordering is load-bearing (same as /login).
  # NOTE: HttpPublic dispatch is path-based (String.ends_with?(.., "/refresh")), so
  # the `action: :refresh` opt is decorative — kept only for parity with the /login
  # forward above (MINOR-3).
  forward "/_matrix/client/v3/refresh", to: Nebu.Matrix.HttpPublic, init_opts: [action: :refresh]

  # S3 device-management: the UIA m.login.sso auth FALLBACK is UNAUTHENTICATED (it IS
  # the auth step) — it must be matched BEFORE the catch-all "/_matrix" forward to the
  # OIDC-protected router. Forwarded to Nebu.Matrix.HttpPublic (no OidcPlug).
  forward "/_matrix/client/v3/auth", to: Nebu.Matrix.HttpPublic, init_opts: [action: :uia_fallback]

  # F-2 (ADR-033): once OAuth is enabled discovery names ONE issuer (Nebu's); the legacy IdP
  # passthrough only serves these three paths while OAuth is disabled.
  forward "/_matrix/client/v1/auth_issuer",
    to: Nebu.Web.Plugs.OAuthDiscovery,
    init_opts: [oauth_action: :auth_issuer, legacy_action: :auth_issuer]

  # epic oauth-broker (ADR-033): the STABLE auth_metadata path is Nebu's OWN RFC 8414 document
  # (Nebu is the authorization server; `issuer` = Nebu's public https URL), served by
  # Nebu.OAuth.Http — 404 M_UNRECOGNIZED while OAuth is disabled. It REPLACES the former IdP
  # passthrough on this path. The unstable org.matrix.msc2965 paths below follow the switch
  # (Nebu document while enabled, legacy passthrough while disabled).
  forward "/_matrix/client/v1/auth_metadata",
    to: Nebu.OAuth.Http,
    init_opts: [action: :auth_metadata]

  # Dynamic Client Registration (RFC 7591), unauthenticated, rate limited, 404 M_UNRECOGNIZED while
  # OAuth is disabled (Nebu.OAuth.Http).
  forward "/oauth2/register", to: Nebu.OAuth.Http, init_opts: [action: :register]

  # Authorization endpoint (story oauth-authorize-idp-delegation-code): browser navigation, HTML
  # pages / 302 redirects, no CORS; 404 M_UNRECOGNIZED while OAuth is disabled. The IdP leg returns
  # through the SHARED callback /_matrix/client/v3/login/sso/redirect/oidc (no /oauth2/callback,
  # ADR-033 D1).
  forward "/oauth2/authorize", to: Nebu.OAuth.Http, init_opts: [action: :authorize]

  # Consent page (story oauth-authorize-freshness, FR7): the user's decision between the IdP login and the
  # authorization code. Browser navigation, server-rendered HTML, strict CSP, NO CORS (cors/2 skips it),
  # its own form-body parsing (JsonBody skips it); 404 page while OAuth is disabled.
  forward "/oauth2/consent", to: Nebu.OAuth.Http, init_opts: [action: :consent]

  # Account-management page (story oauth-account-management): browser navigation, server-rendered HTML,
  # strict CSP, NO CORS (cors/2 skips it), its own form-body parsing (JsonBody skips it). 404 page
  # while OAuth is disabled. Placed with the other OAuth forwards, before the catch-all "/_matrix"
  # forward and `match _`; `/account` and every `/account/*` sub-path.
  forward "/account", to: Nebu.OAuth.Http, init_opts: [action: :account]

  # Token endpoint + Nebu's id_token JWKS (story oauth-token-endpoint): form-encoded POST /
  # GET, CORS `*` without credentials, 404 M_UNRECOGNIZED while OAuth is disabled, 503 {} while the
  # config is unreadable. /oauth2/token reads its raw body itself (JsonBody skips it).
  forward "/oauth2/token", to: Nebu.OAuth.Http, init_opts: [action: :token]

  # Token revocation (RFC 7009, story oauth-token-revocation-logout): same form-POST envelope and
  # credentials-free CORS as the token endpoint, but NO kill switch (it stays live while OAuth is
  # disabled; only an unreadable config answers 503 {}).
  forward "/oauth2/revoke", to: Nebu.OAuth.Http, init_opts: [action: :revoke]
  forward "/oauth2/jwks", to: Nebu.OAuth.Http, init_opts: [action: :jwks]

  forward "/_matrix/client/unstable/org.matrix.msc2965/auth_issuer",
    to: Nebu.Web.Plugs.OAuthDiscovery,
    init_opts: [oauth_action: :auth_issuer, legacy_action: :auth_issuer]

  forward "/_matrix/client/unstable/org.matrix.msc2965/auth_metadata",
    to: Nebu.Web.Plugs.OAuthDiscovery,
    init_opts: [oauth_action: :auth_metadata, legacy_action: :auth_metadata]

  # GET /_matrix/client/v3/profile/{userId}[/displayname|/avatar_url] is
  # unauthenticated per Matrix spec (public profile read). PUT on the same paths
  # IS authenticated and lives in Nebu.Web.Router.Protected. We forward the whole
  # profile subtree to MatrixPublic, which dispatches GET unauthenticated and
  # delegates PUT to the protected router (which re-runs OidcPlug).
  forward "/_matrix/client/v3/profile", to: Nebu.Matrix.HttpPublic, init_opts: [action: :profile]

  # ── AUTHENTICATED media routes (media-gateway-migration) ──────────────────
  # /_matrix/media/v3/{upload,download,thumbnail,preview_url} are served by the
  # Elixir media handler (ported from the Go media gateway). They run OidcPlug in
  # Nebu.Web.Router.Media's own pipeline, so they are authenticated (upload AC1;
  # download/thumbnail/preview_url assert the 401 gate). This MUST be matched
  # before the catch-all "/_matrix" forward, since Plug.Router matches top-down.
  forward "/_matrix/media", to: Nebu.Web.Router.Media

  # Authenticated Matrix Client-Server v1 media endpoints
  # (bugfix-fix-matrix-client-v1-media-routes) — Element Web (spec v1.11+
  # aware) calls these instead of the deprecated `/_matrix/media/v3/*` ones
  # above. Forwarded to a DEDICATED router (Nebu.Web.Router.ClientV1Media)
  # rather than reusing Nebu.Web.Router.Media (code-review cycle 1: reusing
  # the same router made /v3/upload, /v3/preview_url, etc. cross-reachable
  # under this prefix, and made un-versioned /download, /thumbnail aliases
  # reachable under /_matrix/media — both unintended widenings of the URL
  # surface). ClientV1Media runs its own OidcPlug and has only the
  # download/thumbnail clauses this story is scoped to. Must be matched
  # before the catch-all "/_matrix" forward below.
  forward "/_matrix/client/v1/media", to: Nebu.Web.Router.ClientV1Media

  # ── Matrix client discovery — UNAUTHENTICATED, required by every client BEFORE
  #    login (Element/FluffyChat fetch these first; a 401 here means no login UI).
  #    Restored from the Go gateway (matrix-api-migration dropped them). Matched
  #    before the catch-all "/_matrix" forward (Plug.Router is top-down).
  # `GET /_matrix/client/versions` (story oauth-versions-switch, V1/V3): v1.1-v1.15 exactly while the OAuth
  # 2.0 API is offered (the `auth_metadata` 200 predicate), else v1.1-v1.11; the version lists, the
  # `unstable_features` (only the MSC2666 mutual_rooms flag that matrix-js-sdk / Element use to find the
  # unstable path) and the fail-closed rule live in `Nebu.Matrix.HttpPublic.versions/1`. An exact `get`, not a
  # `forward` (a forward would also capture `/_matrix/client/versions/...`).
  get "/_matrix/client/versions" do
    Nebu.Matrix.HttpPublic.versions(conn)
  end

  # Every other method on the exact path (story oauth-room-summary-unrecognized, RU11 / AC11): the endpoint
  # exists, so a wrong method is `405 M_UNRECOGNIZED` + `Allow: GET, OPTIONS` (never the 401 of the
  # Protected pipeline). HEAD is not mapped to GET (no Plug.Head): 405 too. A non-preflight OPTIONS => 204.
  # In both OAuth states and regardless of `Authorization`.
  match "/_matrix/client/versions" do
    Nebu.Web.Unrecognized.respond(conn, ["GET"])
  end

  # `POST /_matrix/client/v3/register` (RU10a): registration is not supported (accounts come from the IdP).
  # Routed explicitly, NOT a fall-through: the spec's "registration not supported" answer is 403 and Element
  # treats it as "registration disabled" (a 404 would read as a broken server). No authentication, no
  # rate-limit token, no DB, no log line, whatever the body, `kind` or token.
  post "/_matrix/client/v3/register" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      403,
      Jason.encode!(%{"errcode" => "M_FORBIDDEN", "error" => "Registration is not enabled on this homeserver."})
    )
  end

  # Other methods on `/v3/register` => 405 + `Allow: POST, OPTIONS`; sub-paths (`/register/available`, ...)
  # stay fall-throughs of the Protected router (404 M_UNRECOGNIZED).
  match "/_matrix/client/v3/register" do
    Nebu.Web.Unrecognized.respond(conn, ["POST"])
  end

  # Nebu's OWN OAuth metadata under the issuer (story oauth-token-endpoint, T31 / oracle C7):
  # matrix-js-sdk's OidcTokenRefresher fetches `<issuer>/.well-known/openid-configuration` before
  # every refresh. Same document as /_matrix/client/v1/auth_metadata, never the IdP's.
  forward "/.well-known/openid-configuration", to: Nebu.OAuth.Http, init_opts: [action: :openid_configuration]

  get "/.well-known/matrix/client" do
    scheme = Nebu.Web.RequestScheme.scheme(conn)

    host =
      case get_req_header(conn, "host") do
        [h | _] -> h
        _ -> "#{conn.host}:#{conn.port}"
      end

    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "m.homeserver" => %{"base_url" => scheme <> "://" <> host},
        # Element-proprietary well-known hint (NOT Matrix spec; ignored by other
        # clients). Tells Element-family clients not to offer per-room encryption,
        # matching the server's managed posture which rejects m.room.encryption
        # (ADR-011). Static current default — see story wellknown-e2ee-default.
        "io.element.e2ee" => %{"force_disable" => true}
      })
    )
  end

  # ── AUTHENTICATED Matrix routes ───────────────────────────────────────────
  # Everything else under /_matrix runs OidcPlug first (Protected's pipeline).
  forward "/_matrix", to: Nebu.Web.Router.Protected

  # ── Admin UI (admin-ui-migration) ─────────────────────────────────────────
  # The /admin subtree (and the LiveView /admin/live socket) is served by the
  # Phoenix LiveView Admin UI. We dispatch to Nebu.Admin.Endpoint WITHOUT using
  # Plug.Router's `forward` because forward strips the matched prefix from
  # path_info — the Phoenix router needs the full "/admin/..." path to match its
  # routes. So we match the prefix and call the endpoint with the original conn,
  # preserving path_info. This keeps the whole admin app on the SAME Bandit
  # listener as Matrix/media (no second port). Disabled in test (the endpoint is
  # not started under the Application there).
  match "/admin", do: dispatch_admin(conn)
  match "/admin/*_rest", do: dispatch_admin(conn)

  match _ do
    send_resp(conn, 404, "not found")
  end

  defp dispatch_admin(conn) do
    if admin_endpoint_running?() do
      Nebu.Admin.Endpoint.call(conn, Nebu.Admin.Endpoint.init([]))
    else
      send_resp(conn, 404, "not found")
    end
  end

  defp admin_endpoint_running? do
    Process.whereis(Nebu.Admin.Endpoint) != nil
  end

  @cors_opts CORSPlug.init([])
  @cors_oauth_opts CORSPlug.init(credentials: false)

  # The account page is browser navigation (story oauth-account-management, A4): no CORSPlug at all, so no
  # preflight is answered (a stray OPTIONS gets the 405 page) and no `access-control-*` header is added.
  defp cors(%Plug.Conn{path_info: ["account" | _]} = conn, _opts), do: conn

  # The consent page is browser navigation too (story oauth-authorize-freshness, FR7): no CORSPlug, so a
  # preflight is not answered (a stray OPTIONS gets the 405 page) and no `access-control-*` header appears.
  defp cors(%Plug.Conn{path_info: ["oauth2", "consent" | _]} = conn, _opts), do: conn

  # The legacy SSO confirmation page (story legacy-sso-redirect-confirmation, G3-3, D11) is browser navigation too:
  # no CORSPlug, so no `access-control-*` header and a preflight is not answered by CORSPlug (it reaches the
  # route fall-through of the Matrix public router, which answers 204 + Allow).
  defp cors(%Plug.Conn{path_info: ["_matrix", "client", "v3", "login", "sso", "confirm" | _]} = conn, _opts), do: conn

  defp cors(%Plug.Conn{path_info: ["oauth2", endpoint | _]} = conn, _opts) when endpoint in ["token", "jwks", "revoke"],
    do: CORSPlug.call(conn, @cors_oauth_opts)

  defp cors(%Plug.Conn{path_info: [".well-known", "openid-configuration" | _]} = conn, _opts),
    do: CORSPlug.call(conn, @cors_oauth_opts)

  defp cors(conn, _opts), do: CORSPlug.call(conn, @cors_opts)

  # F-5: set X-Content-Type-Options: nosniff on every response (including those
  # produced by the forwarded sub-routers and CORSPlug's halted preflight), via a
  # before_send callback registered at the front of the pipeline. All Nebu
  # responses are application/json Matrix envelopes, so this prevents any
  # MIME-sniffing edge case on a misbehaving client without affecting behaviour.
  defp security_headers(conn, _opts) do
    register_before_send(conn, fn conn ->
      put_resp_header(conn, "x-content-type-options", "nosniff")
    end)
  end
end
