defmodule Nebu.Web.Router.Media do
  @moduledoc """
  Matrix content-repository routes (deprecated `/_matrix/media/v3/*`),
  forwarded here from `Nebu.Web.Router` under the `/_matrix/media` prefix.

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

  plug Nebu.Web.Plugs.OidcPlug
  plug :match
  plug :dispatch

  put "/v3/upload" do
    conn = Nebu.Web.Plugs.RateLimit.call(conn, @upload_rate_limit)
    if conn.halted, do: conn, else: Media.upload(conn)
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

  match _ do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{"errcode" => "M_NOT_FOUND", "error" => "Unrecognized request"}))
  end
end
