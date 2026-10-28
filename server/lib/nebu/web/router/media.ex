defmodule Nebu.Web.Router.Media do
  @moduledoc """
  Matrix content-repository routes (deprecated `/_matrix/media/v3/*`),
  forwarded here from `Nebu.Web.Router` under the `/_matrix/media` prefix.

  The authenticated Matrix Client-Server `v1` media endpoints
  (`/_matrix/client/v1/media/download`, `/_matrix/client/v1/media/thumbnail`)
  are served by the SEPARATE `Nebu.Web.Router.ClientV1Media` router, not this
  one (bugfix-fix-matrix-client-v1-media-routes, code-review cycle 1: sharing
  this router made `/v3/upload`, `/v3/preview_url`, etc. cross-reachable via
  the `v1` prefix, and made un-versioned `/download`/`/thumbnail` aliases
  reachable via THIS router's `/_matrix/media` prefix — both unintended). See
  `Nebu.Web.Router.ClientV1Media`'s moduledoc for the full rationale.

  `Nebu.Web.Plugs.OidcPlug` runs in this router's pipeline, so EVERY media route
  is authenticated (test-review MIN-2: media routes MUST sit behind OidcPlug;
  upload requires auth per AC1, download/thumbnail/preview_url all assert the
  401 gate). On success OidcPlug assigns `conn.assigns.current_user`, which
  `Nebu.Media` uses as the trusted identity for the membership check.

  The handler module produces its own `404 M_NOT_FOUND` for unknown media
  (test-review MIN-1) — the `match _` fallback here is only for unrecognized
  media sub-paths.

  ## Rate limiting (security-review F-1 — outbound-fetch amplifier / abuse)

  Per-IP `Nebu.Web.Plugs.RateLimit` is applied inline to the two expensive
  endpoints, mirroring the Go media gateway's per-IP limiter
  (`media/internal/ratelimit/ratelimit.go`):

    * `preview_url` — STRICT tier (30/min, burst 10). `preview_url` makes Nebu
      perform an outbound HTTP fetch to a caller-chosen URL on every request, so
      even behind OidcPlug it is an egress-DoS reflector / public-host hammering
      amplifier. The Go gateway capped it; the Elixir migration must not drop
      that control. Matches the Go gateway's `strict` tier (login, 30/min b10).
    * `upload` — 600/min burst 5, mirroring the Go media gateway's upload tier
      (10 req/s, burst 5). Upload is expensive (read body + AES-256-GCM encrypt +
      S3 PUT), so it carries the Go-parity abuse cap.

  `NEBU_RATE_LIMIT_DISABLED` makes the plug a no-op (integration/e2e suites are
  not throttled). The buckets key on the directly-connected peer IP.
  """
  use Plug.Router

  alias Nebu.Media

  # F-1: strict per-IP limit on the outbound-fetch amplifier (Go `strict` parity).
  @preview_rate_limit Nebu.Web.Plugs.RateLimit.init(
                        rate_per_min: 30,
                        burst: 10,
                        tier: "preview_url"
                      )
  # F-1: Go media upload-tier parity (10 req/s = 600/min, burst 5).
  @upload_rate_limit Nebu.Web.Plugs.RateLimit.init(
                       rate_per_min: 600,
                       burst: 5,
                       tier: "media_upload"
                     )

  # Pipeline (story oauth-room-summary-unrecognized, RU10): :match runs BEFORE authentication so the
  # catch-all (marked `nebu_unrecognized: true`) answers an unimplemented endpoint with a spec
  # `M_UNRECOGNIZED` without a credential check; every real route still runs the OidcPlug.
  plug :match
  plug :authenticate
  plug :dispatch

  @doc """
  Runs `Nebu.Web.Plugs.OidcPlug` for every matched route; skipped ONLY when the catch-all marked the conn
  (`conn.private[:nebu_unrecognized] === true`, strict boolean, fail closed).
  """
  @spec authenticate(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def authenticate(%Plug.Conn{private: %{nebu_unrecognized: true}} = conn, _opts), do: conn
  def authenticate(conn, _opts), do: Nebu.Web.Plugs.OidcPlug.call(conn, Nebu.Web.Plugs.OidcPlug.init([]))

  post "/v3/upload" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @upload_rate_limit)
    if conn.halted, do: conn, else: Media.upload(conn)
  end

  # media-security-admin-control/2b-put-media-upload: async-upload companion
  # (Matrix v1.7+, core-stable). Reuses the same @upload_rate_limit tier as
  # the synchronous route above — exactly as expensive per request.
  put "/v3/upload/:server_name/:media_id" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @upload_rate_limit)
    if conn.halted, do: conn, else: Media.upload_async(conn, server_name, media_id)
  end

  # media-security-admin-control/2a-post-media-create: reservation half of
  # Matrix's async upload flow (core-stable since v1.7, no MSC/unstable-
  # capability gate). No new rate-limit tier here — AC3's 429 is a per-user
  # pending-reservation-count business check inside Media.create/1, not the
  # per-IP token bucket used by upload/preview_url above.
  post "/v1/create" do
    Media.create(conn)
  end

  get "/v3/download/:server_name/:media_id/:file_name" do
    Media.download(conn, server_name, media_id, file_name)
  end

  get "/v3/download/:server_name/:media_id" do
    Media.download(conn, server_name, media_id)
  end

  get "/v3/thumbnail/:server_name/:media_id" do
    Media.thumbnail(conn, server_name, media_id)
  end

  get "/v3/preview_url" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @preview_rate_limit)
    if conn.halted, do: conn, else: Media.preview_url(conn)
  end

  # Fall-through (RU9 - RU11): 404 for an unknown path, 405 + Allow when another method routes here.
  match _, private: %{nebu_unrecognized: true} do
    Nebu.Web.Unrecognized.respond(conn, allowed_methods(conn))
  end

  # The methods this router has a real clause for at the request path (a probe selects a clause, it never
  # dispatches; the marker is removed first, RU11).
  defp allowed_methods(conn) do
    path = Plug.Router.Utils.decode_path_info!(conn)
    conn = %{conn | private: Map.delete(conn.private, :nebu_unrecognized)}

    Nebu.Web.Unrecognized.probe(conn, fn c ->
      do_match(c, c.method, path, c.host).private[:nebu_unrecognized] !== true
    end)
  end
end
