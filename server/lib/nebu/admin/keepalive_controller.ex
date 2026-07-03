defmodule Nebu.Admin.KeepaliveController do
  @moduledoc """
  `GET /admin/keepalive` — admin-liveview-session-refresh (AC3/AC4).

  ## Why this exists

  `Nebu.Admin.Auth.fetch_current_user/2` (the existing silent-OIDC-refresh plug,
  AC3/AC5/AC6 of `admin-oidc-session-refresh`) only runs on a genuine HTTP round-trip
  through the `:browser` pipeline. The two remaining Admin LiveViews (Dashboard,
  AuditLog — Bootstrap is now a plain HTTP controller, not a LiveView) run over a
  persistent WebSocket: while an operator idles on an open LiveView tab with no new
  HTTP request, `fetch_current_user/2` never re-runs, so the stored OIDC refresh
  token is never used and the operator is force-logged-out at `id_token.exp` even
  though the refresh token is still valid.

  This endpoint is the deliberately minimal HTTP round-trip a client-side heartbeat
  (JS hook, see `/admin/static/assets/app.js`) polls periodically while any admin
  LiveView is mounted. It is intentionally a near-no-op: it sits behind the exact
  same `:browser` pipeline + `require_admin` gate as every other admin route, so
  simply reaching this action means `fetch_current_user/2` (which runs earlier in
  the pipeline) already had the chance to perform its existing pre-expiry refresh.
  No new refresh/business logic is introduced here — see AC4.

  ## Security (AC4)

    * Same admin auth gate as every other `:browser` route (`plug Nebu.Admin.Auth,
      :require_admin`) — no bypass.
    * Minimal response: `204 No Content`, empty body. No session/token/PII payload.
    * No logging of any request-specific data (no sub/email/token material).
    * Behaves like the normal non-refresh path when `admin_oidc_refresh_mode =
      "online"` (no refresh token stored) — `fetch_current_user/2` already handles
      that case (logs an operator-facing warning, does not raise); this action does
      nothing beyond that.
  """
  use Phoenix.Controller, formats: [:html]

  plug Nebu.Admin.Auth, :require_admin

  @doc """
  Minimal success response. Reaching this action already means the `:browser`
  pipeline's `fetch_current_user/2` ran (and, if inside the pre-expiry window with a
  valid stored refresh token, silently refreshed the session) — this action performs
  no additional work.
  """
  def index(conn, _params) do
    send_resp(conn, 204, "")
  end
end
