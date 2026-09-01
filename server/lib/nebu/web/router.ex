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
  plug Nebu.Web.Plugs.RequestLogger
  plug :security_headers
  plug CORSPlug
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
  #   * GET  /_matrix/client/{v1,unstable}/auth_issuer / auth_metadata (MSC2965)
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

  forward "/_matrix/client/v1/auth_issuer",
    to: Nebu.Matrix.HttpPublic,
    init_opts: [action: :auth_issuer]

  forward "/_matrix/client/v1/auth_metadata",
    to: Nebu.Matrix.HttpPublic,
    init_opts: [action: :auth_metadata]

  forward "/_matrix/client/unstable/org.matrix.msc2965/auth_issuer",
    to: Nebu.Matrix.HttpPublic,
    init_opts: [action: :auth_issuer]

  forward "/_matrix/client/unstable/org.matrix.msc2965/auth_metadata",
    to: Nebu.Matrix.HttpPublic,
    init_opts: [action: :auth_metadata]

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
  get "/_matrix/client/versions" do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      200,
      Jason.encode!(%{
        "versions" => ~w(v1.1 v1.2 v1.3 v1.4 v1.5 v1.6 v1.7 v1.8 v1.9 v1.10 v1.11)
      })
    )
  end

  get "/.well-known/matrix/client" do
    scheme =
      case get_req_header(conn, "x-forwarded-proto") do
        ["https" | _] -> "https"
        _ -> if conn.scheme == :https, do: "https", else: "http"
      end

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
