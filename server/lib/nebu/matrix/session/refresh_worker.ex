defmodule Nebu.Matrix.Session.RefreshWorker do
  @moduledoc """
  Server-paced background refresh worker for opaque Matrix sessions
  (story `server-paced-session-refresh/background-session-refresh-worker`).

  Element Web's legacy SSO redirect + token-login flow never calls
  `POST /_matrix/client/v3/refresh` — the opaque access token it receives at
  login is otherwise fire-and-forget and simply expires at the bound
  `matrix_sessions.expires_at` (`min(oidc_exp, now + 8h)`, computed by
  `Nebu.Matrix.HttpPublic.session_expires_at/1`). This worker proactively
  redeems each device's stored, encrypted upstream OIDC refresh token shortly
  before that bound is reached, so the client never needs to call `/refresh`
  and never sees a 401 as long as the upstream account stays valid.

  ## Design (ADR-018 / ADR-021)

  Plain `GenServer`, `Process.send_after` scheduling loop, inline SQL — no
  Repository/Service layer, no external job queue. Mirrors the existing
  `Nebu.Matrix.Session.Sweeper` template: `handle_info(:refresh, state)` runs
  one cycle then reschedules itself; a crash just means the supervisor
  restarts the worker and the next tick fires up to one interval late
  (Postgres — not this process — is the source of truth for what still needs
  refreshing, so a missed tick is never a correctness issue, only a delay).

  ## Per-row grain (AC2)

  Iterates `matrix_sessions` ROWS, not users — each `(user_id, device_id)`
  refresh is fully independent. One device's upstream rejection/decrypt
  failure/DB hiccup is caught and logged; it never aborts the cycle or
  affects any other row, including sibling devices of the same user.

  ## Grace-period-safe selection (AC4)

  The candidate query selects only `revoked_at IS NULL` rows nearing their
  bound. A soft-revoked grace-period sibling (`revoked_at IS NOT NULL`,
  possibly still inside its `grace_until` window) is NEVER selected — the
  worker must not extend or otherwise touch a stale rotated-away row.

  ## TOCTOU-safe execution (AC3)

  Row selection happens once per cycle; by the time a given row would be
  redeemed, an unrelated request (e.g. `delete_one_device`) may have deleted
  or revoked it. The worker therefore RE-SELECTS the row (`revoked_at IS
  NULL`) immediately before invoking the IdP-exchange seam
  (`revalidate_with_idp/1`) — no earlier. If the re-check finds the row gone
  or revoked, the worker skips it without calling the IdP and without any
  chance of resurrecting it afterwards.

  ## Bounded rolling TTL (AC5) / fail-closed (AC6)

  On success, the new `expires_at` is computed by the SAME
  `Nebu.Matrix.HttpPublic.session_expires_at/1` login/`/refresh` already use
  (`min(fresh_claims["exp"], now + Nebu.Web.SessionConfig.matrix_session_ttl_seconds())`)
  — never re-implemented here, never unbounded. On failure, no local-only
  fallback extension and no retry loop within the same cycle ever runs — the
  session, at worst, expires normally at its already-set `expires_at`,
  producing the SAME pre-existing 401 `M_UNKNOWN_TOKEN` + `soft_logout: true`
  shape as any other natural expiry (`OidcPlug.call_opaque/1` — untouched by
  this story). code-review cycle-1 MAJOR fix (M1): failures are NOT all
  treated identically anymore — mirroring `do_refresh_with/2`'s existing
  asymmetry, a CONFIRMED rejection/deprovisioning signal (e.g. `:deactivated`,
  an actual IdP rejection, decrypt failure) hard-deletes the session row
  immediately, tightening the window instead of relying solely on the bounded
  TTL. A merely TRANSIENT/ambiguous error still just logs and leaves the row
  alone, since it is not proof of deprovisioning; a later cycle may retry once
  the transient issue clears. TOCTOU misses (row already gone/revoked) are a
  no-op, not an error at all.

  security-review fix cycle-2 (HIGH finding #1): the confirmed-rejection
  hard-delete is scoped to the EXACT row this worker re-selected
  (`Store.delete_by_access_token_hash/1`, guarded by the row's hash AND
  `revoked_at IS NULL`) — NOT the wider `(user_id, device_id)` pair
  `Store.delete_for_user_device/2` deletes. See "Cluster safety" below for
  why the wide-scoped delete is unsafe here specifically (it is safe, and
  still used, for the client-driven `/refresh` path and explicit
  user-initiated device removal, neither of which has a sibling winner
  racing the delete).

  security-review fix cycle-2 (MEDIUM finding #2): the transient/confirmed
  classification (`transient?/1`) now ALSO treats
  `{:token_endpoint_unreachable, _}` and `{:discovery_failed, _}` (IdP
  network timeout / discovery outage) as transient, alongside the
  pre-existing `{:transient_check_failed, _}` tag. Only a genuine confirmed
  rejection (e.g. `:deactivated`, an explicit IdP-side rejection of THIS
  refresh token) still hard-deletes. Without this, a brief IdP outage during
  one cycle would mass-hard-delete every near-expiry session across every
  device/user this cycle touches — the worker's fan-out (unlike the single
  request the client `/refresh` path handles) turns a transient blip into a
  mass, self-inflicted DoS.

  security-review fix cycle-3 (MEDIUM finding #4): `transient?/1` now ALSO
  treats `{:token_endpoint_status, status}` as transient when `status >= 500`
  or `status == 429` — an IdP 5xx (e.g. a Keycloak/Dex pod restart or rolling
  deploy) or 429 (rate limiting/throttling) is an IdP-availability problem,
  not the IdP confirming THIS refresh token was rejected. `{:token_endpoint_status,
  status}` for 400/401/403 (and any other unexpected status) still counts as
  confirmed rejection and hard-deletes, unchanged. Without this narrowing, a
  brief IdP 5xx/429 window during a rolling restart or overload would
  mass-hard-delete every near-expiry session this cycle touches — the same
  class of self-inflicted DoS as finding #2, just gated on the raw HTTP status
  code path instead of the network/discovery-failure path.

  ## In-place extension, never rotation (matrix-session-refresh-fixes AC1/AC2)

  The worker NEVER rotates the opaque access/refresh token: the client never
  receives rotated tokens, so rotating would log it out (revoked AT -> 401 without
  `soft_logout`, old RT eventually unusable). A successful IdP re-validation only
  updates `expires_at` (and a provider-rotated encrypted OIDC refresh token) on the
  SAME row via `Store.extend_in_place_by_hash/3` (keyed by the row's hash, guarded by
  `revoked_at IS NULL`). The worker only ever knows rows by their `access_token_hash`
  (matrix_sessions holds no plaintext token), hence the `*_by_hash` store variants.
  No new row, no `revoked_at`, no pending/consumed state change. The
  client's own `/refresh` and the worker therefore never invalidate each other.

  ## Reuse, not duplication (AC1/AC6, story Dev Note 2)

  All actual IdP-exchange, decrypt, and rotation mechanics are delegated to
  the existing `Nebu.Matrix.HttpPublic.revalidate_with_idp/1` (which itself
  calls through `exchange_oidc_refresh_token/1`, honoring the
  `:matrix_oidc_refresh_override` test seam) and
  `Nebu.Matrix.Session.MatrixSessionStore.extend_in_place/3`. This worker
  contains zero HTTP/JWT logic of its own.

  ## Cluster safety (ADR-020)

  Row selection is deterministic wall-clock comparison, so multiple nodes MAY
  select and attempt to redeem the same row concurrently. The worker never
  rotates: `Store.extend_in_place/3` is one atomic statement guarded by
  `revoked_at IS NULL`, so racing nodes simply both extend the same row (the
  last write wins, harmless). If a client `/refresh` rotated the row away first,
  `extend_in_place/3` matches 0 rows and the worker skips the extension; a
  provider-rotated OIDC refresh token obtained from the IdP is then written to
  the device's CURRENT active row (`Store.store_rotated_oidc_rt/3`, guarded by
  `revoked_at IS NULL`) so the rotating IdP's new token is not lost. Two nodes (or
  the worker and `/refresh`) redeeming the SAME OIDC refresh token at the same
  time against a rotating IdP stays an accepted, pre-existing limitation: the
  loser's redemption fails and is classified by `RefreshErrors`.

  security-review fix cycle-2 (HIGH finding #1): the extension path above is
  race-safe, but the fail-closed hard-delete path originally was
  NOT — it deleted by `(user_id, device_id)` (`delete_for_user_device/2`),
  reaching across to any row for that device, not just the one this worker
  acted on. Since upstream IdPs (Dex default, RFC 9700 recommendation) rotate
  the refresh token on redemption, two nodes racing the SAME upstream RT
  produce exactly one winner (who rotates to a brand-new healthy row) and one
  loser (whose redemption fails because the RT was already consumed). If the
  loser's failure were treated as confirmed rejection and hard-deleted by the
  wide `(user_id, device_id)` scope, it would delete the WINNER's freshly
  rotated row — an attacker-independent, self-inflicted DoS forcing
  unnecessary re-login on an actively-refreshed, legitimate session. Fixed by
  scoping the delete to `Store.delete_by_access_token_hash(sess.access_token_hash)`
  (guarded by `revoked_at IS NULL`) — the same true per-row
  atomicity `rotate_tokens/1`'s guarded UPDATE already has, so a loser's
  delete against an already-superseded row matches 0 rows and cannot touch
  the winner's replacement.
  """
  use GenServer

  require Logger

  alias Nebu.Matrix.HttpPublic
  alias Nebu.Matrix.Session.RefreshErrors
  alias Nebu.Matrix.Session.MatrixSessionStore, as: Store

  @default_interval_ms 5 * 60 * 1000
  @default_lookahead_seconds 60 * 60

  @doc """
  Starts the worker. `opts` is currently unused (mirrors
  `Nebu.Matrix.Session.Sweeper.start_link/1`'s shape) — kept as an arity-1
  function so `start_supervised!/1` and direct supervision-tree registration
  both work without a fixed, collision-prone process name.
  """
  def start_link(opts \\ []) when is_list(opts), do: GenServer.start_link(__MODULE__, :ok)

  @impl true
  def init(:ok) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    refresh()
    schedule()
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp schedule, do: Process.send_after(self(), :refresh, interval_ms())

  defp interval_ms,
    do: Application.get_env(:nebu_http, :matrix_refresh_worker_interval_ms, @default_interval_ms)

  defp lookahead_seconds do
    Application.get_env(
      :nebu_http,
      :matrix_refresh_worker_lookahead_seconds,
      @default_lookahead_seconds
    )
  end

  # ── One refresh cycle ────────────────────────────────────────────────────

  defp refresh do
    if Process.whereis(Nebu.Repo) do
      candidates()
      |> Enum.each(&refresh_row/1)
    end

    :ok
  rescue
    e ->
      Logger.error("matrix refresh worker: cycle failed", reason: inspect(e))
      :ok
  end

  # AC4: only the currently-ACTIVE row (revoked_at IS NULL) per (user_id,
  # device_id) that is within the lookahead window is a candidate. Since only
  # one row per device can ever have revoked_at IS NULL at a time (rotation
  # soft-revokes the old row before inserting the new one), a plain
  # `revoked_at IS NULL` filter already excludes every soft-revoked (pending or
  # consumed) sibling — no GROUP BY/window function is needed.
  # code-review cycle-1 MINOR (m3): "only one non-revoked row per device" is an
  # INVARIANT MAINTAINED BY CONVENTION in `rotate_tokens/1` (it always
  # soft-revokes the old row in the same transaction as inserting the new
  # one) — it is NOT enforced by a DB constraint (e.g. no partial unique index
  # on `(user_id, device_id) WHERE revoked_at IS NULL`). If that convention is
  # ever violated by a future code path, this filter would silently select
  # more than one "active" row per device.
  # story oauth-token-endpoint (T27): only `auth_api = 'legacy'` rows are candidates.
  # N-3: rows at/over the absolute cap (created_at + session TTL) are NOT candidates:
  # they can never be extended again, so redeeming the IdP RT would be a no-op that
  # only keeps resetting the IdP idle timer. The client's own /refresh re-validates.
  defp candidates do
    case safe_query(
           """
           SELECT access_token_hash
             FROM matrix_sessions
            WHERE revoked_at IS NULL
              AND auth_api = 'legacy'
              AND expires_at <= NOW() + ($1 * INTERVAL '1 second')
              AND created_at + ($2::bigint * INTERVAL '1 second') > NOW()
           """,
           [lookahead_seconds(), Nebu.Web.SessionConfig.matrix_session_ttl_seconds()]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [access_token_hash] -> access_token_hash end)
      {:error, _} -> []
    end
  end

  # AC3 (TOCTOU): re-select the row by access_token immediately before doing
  # anything else — in particular before calling revalidate_with_idp/1 (the
  # IdP-exchange seam). If the row is gone or has been revoked since the
  # candidate list was built, skip it silently (fail-closed, no resurrection).
  defp refresh_row(access_token_hash) do
    case Store.get_by_access_token_hash(access_token_hash) do
      # story oauth-token-endpoint (T27): OAuth sessions are never extended/deleted by this worker
      # (spec 6: no background worker for OAuth sessions; their clients refresh at /oauth2/token).
      {:ok, %{auth_api: api}} when api != "legacy" ->
        :ok

      {:ok, %{revoked_at: nil} = sess} ->
        redeem(sess)

      {:ok, _revoked} ->
        :ok

      :error ->
        :ok
    end
  rescue
    e ->
      Logger.error("matrix refresh worker: row refresh crashed, skipping",
        reason: inspect(e)
      )

      :ok
  end

  # Calls straight through the existing HttpPublic redemption path — no
  # duplicated IdP-exchange or decrypt logic here (AC1/AC6, Dev Note 2). The
  # TOCTOU re-check above happens IMMEDIATELY before this call, satisfying
  # AC3's "no earlier than the moment the worker is about to call the IdP"
  # requirement regardless of how HttpPublic itself is structured internally.
  #
  # code-review cycle-1 MAJOR fix (M1): mirror `do_refresh_with/2`'s existing
  # asymmetry between a CONFIRMED rejection/deprovisioning signal and a merely
  # transient one, instead of treating every error identically. `do_refresh_with/2`
  # hard-deletes the session row (`Store.delete_for_user_device/2`) on any
  # `{:error, reason}` EXCEPT the tagged `{:error, {:transient_check_failed, _}}`
  # case (a DB hiccup while re-checking is_active — NOT proof of deprovisioning).
  # The background worker now does exactly the same: a confirmed rejection
  # (`:deactivated`, an IdP-side rejection, decrypt failure, etc.) hard-deletes
  # the row immediately, tightening the window instead of only relying on the
  # bounded-TTL fail-safe (AC5/AC6). A transient failure still just logs and
  # leaves the row alone, so a later cycle can retry once the transient issue
  # clears — this is a deliberate mirroring of the existing client-driven path,
  # not a new invention, and builds no retry/guarantee machinery of its own.
  # security-review fix (server-paced-session-refresh / background-session-refresh-worker,
  # MEDIUM finding #2): `{:token_endpoint_unreachable, _}` (network
  # timeout/IdP-down, oidc_token_exchange.ex ~103) and `{:discovery_failed, _}`
  # (discovery document fetch failure, oidc_token_exchange.ex ~79) are INFRA
  # outages, not proof the upstream IdP rejected THIS refresh token. Unlike the
  # single-request client `/refresh` path, this worker fans out over EVERY
  # near-expiry session on EACH cycle — misclassifying a transient IdP outage
  # as confirmed rejection would mass-hard-delete every near-expiry session
  # across all devices/users for the duration of one outage window. Treat
  # these the SAME as `{:transient_check_failed, _}`: log and leave the row
  # alone, relying on the bounded TTL (AC5/AC6) — a later cycle retries once
  # the outage clears. Only a genuine confirmed rejection/deprovisioning
  # signal (e.g. `:deactivated`, an explicit `{:token_endpoint_status, _}`
  # meaning the IdP explicitly rejected THIS refresh token as invalid/revoked,
  # decrypt failure, etc.) still hard-deletes.
  #
  # security-review fix cycle-3 (MEDIUM finding #4): `{:token_endpoint_status,
  # status}` (oidc_token_exchange.ex ~line 100) carries the RAW non-2xx HTTP
  # status the IdP's token endpoint returned. A 5xx (IdP server error — e.g.
  # a Keycloak/Dex pod restart or rolling deploy) or 429 (rate limiting /
  # throttling) is an IdP-AVAILABILITY problem, not proof that THIS specific
  # refresh token was rejected — yet treating it as confirmed rejection would
  # mass-hard-delete every near-expiry session this cycle touches during a
  # single IdP restart/overload window, the same class of self-inflicted DoS
  # already fixed for MEDIUM finding #2, just gated on a different (arguably
  # more common) trigger. Only a status the IdP uses to explicitly say "this
  # token is invalid/revoked/forbidden" (400 Bad Request, 401 Unauthorized,
  # 403 Forbidden — the confirmed-rejection family) still hard-deletes. Any
  # OTHER unexpected status remains conservatively classified as confirmed
  # rejection, matching the existing fail-closed-in-direction philosophy for
  # genuinely unknown codes — this fix narrows ONLY the known-transient 5xx/429
  # family, it does not broaden transience to arbitrary status codes.
  # Classification lives in `RefreshErrors.transient?/1` (shared with /refresh).

  defp redeem(sess) do
    case HttpPublic.revalidate_with_idp(sess) do
      {:ok, fresh_claims, new_oidc_rt} ->
        extend(sess, fresh_claims, new_oidc_rt)

      {:error, reason} ->
        if RefreshErrors.transient?(reason) do
          Logger.warning(
            "matrix refresh worker: transient failure re-checking active status, session left intact",
            user_id: sess.user_id,
            device_id: sess.device_id,
            reason: RefreshErrors.describe(reason)
          )

          :ok
        else
          Logger.warning(
            "matrix refresh worker: confirmed upstream rejection, hard-invalidating session",
            user_id: sess.user_id,
            device_id: sess.device_id,
            reason: RefreshErrors.describe(reason)
          )

          # security-review fix (HIGH finding #1): scope the fail-closed
          # delete to the EXACT row this worker re-selected and acted on
          # (`sess.access_token_hash`, still-active at the TOCTOU re-check above),
          # NOT the wider (user_id, device_id) pair. Under the supported
          # clustered deployment, a sibling node may have already WON a race
          # to redeem the same (rotating) upstream refresh token and rotated
          # this device to a brand-new healthy row before this node's own
          # redemption attempt failed. `delete_by_access_token_hash/1` is guarded
          # by `WHERE access_token_hash = $1 AND revoked_at IS NULL`, giving this
          # delete the same true per-row atomicity `rotate_tokens/1`'s
          # guarded UPDATE already has: if the winner already soft-revoked
          # (or deleted) this exact row, this delete matches 0 rows and
          # cannot reach across to touch the winner's new row. The bounded
          # TTL (AC5/AC6) still covers the case where this delete itself
          # were ever to fail/miss.
          :ok = Store.delete_by_access_token_hash(sess.access_token_hash)
          :ok
        end
    end
  end

  # AC1/AC5: extend the SAME row in place. new_expires_at is derived from
  # session_expires_at/1 — the SAME min(oidc_exp, now+ceiling) cap login and
  # `/refresh` use. Tokens are never rotated here (the client would not learn them).
  defp extend(sess, fresh_claims, new_oidc_rt) do
    new_expires_at = HttpPublic.session_expires_at(fresh_claims)

    enc_oidc_rt =
      if is_binary(new_oidc_rt) and new_oidc_rt != "",
        do: Nebu.Web.SecretBox.encrypt(new_oidc_rt),
        else: nil

    case Store.extend_in_place_by_hash(sess.access_token_hash, new_expires_at, enc_oidc_rt) do
      :ok ->
        Logger.info("matrix refresh worker: session revalidated (expiry extended up to the absolute cap)",
          user_id: sess.user_id,
          device_id: sess.device_id
        )

        :ok

      :error ->
        # The row was revoked/deleted between the re-check above and this call
        # (e.g. a racing /refresh rotation, logout or delete_one_device). The
        # winner determined the outcome; nothing to extend. Not an error.
        # M3: but a provider-rotated OIDC RT must not be dropped (the IdP already
        # invalidated the previous one): persist it on the device's CURRENT active
        # row, if any (guarded, never resurrects a revoked/deleted device).
        if enc_oidc_rt do
          _ = Store.store_rotated_oidc_rt(sess.user_id, sess.device_id, enc_oidc_rt)
        end

        Logger.info(
          "matrix refresh worker: extend skipped (row no longer active — concurrent refresh or deletion)",
          user_id: sess.user_id,
          device_id: sess.device_id
        )

        :ok
    end
  end

  defp safe_query(sql, params) do
    Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)
  rescue
    e -> {:error, e}
  end
end
