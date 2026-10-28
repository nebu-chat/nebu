defmodule Nebu.Web.Plugs.OidcPlug do
  @moduledoc """
  Validates OIDC Bearer tokens against the cached JWKS public keys.

  On success: assigns `conn.assigns.current_user = "@<sub>:<server_name>"` and
  passes the connection through (no halt). The verified claims are also assigned
  as `conn.assigns.oidc_claims` so downstream handlers (e.g. profile self-checks)
  can read them without re-parsing the token.

  On failure: responds with a `401` Matrix-error JSON envelope and halts:

    * Missing header / non-Bearer scheme → `M_MISSING_TOKEN` "Missing access token"
    * Expired (`exp` in the past)        → `M_UNKNOWN_TOKEN` "Access token has expired"
      + `soft_logout: true` (bugfix-jwt-soft-logout: the underlying session is
      still intact, so the client can recover via refresh/re-auth)
    * Bad signature / iss / aud / kid / alg / malformed → `M_UNKNOWN_TOKEN`

  ## JWKS source seam

  Keys are read from the Application-env override `:nebu_http, :oidc_jwks` when
  present (used by unit tests to inject a public JWK without a network call),
  otherwise from `Nebu.Web.JwksCache.keys/0`.

  ## Security hardening (matrix-api-migration, test-review MINOR-2)

  * MEDIUM-2 — strict alg allowlist: the JWT header `alg` MUST be an asymmetric
    signature algorithm (RS*/ES*/PS*). `none` and all HMAC algorithms (HS*) are
    rejected with `{:error, :unexpected_alg}`. This blocks the alg-confusion attack
    (HMAC-signing a token with the RSA public key as the shared secret) and `alg:none`.
  * MEDIUM-3 — fail-closed iss/aud: when `oidc_issuer` / `oidc_audience` are not
    configured, verification is rejected (`{:error, :issuer_not_configured}` /
    `:audience_not_configured`) — a missing config can no longer fail OPEN. A token
    whose iss/aud does not match the configured value is also rejected.
  """
  @behaviour Plug

  import Plug.Conn

  require Logger

  # Asymmetric signature algorithms only. `none` and HMAC (HS*) are intentionally
  # absent so a token signed with the public key as an HMAC secret, or with no
  # signature at all, is rejected before any verification work happens.
  @allowed_algs ~w(RS256 RS384 RS512 ES256 ES384 ES512 PS256 PS384 PS512)

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # oidc-session-refresh: an opaque Nebu access token (64 hex chars, no ".") is
    # validated against the matrix_sessions store instead of JWKS. A token WITH a
    # "." is a JWT and takes the existing verification path unchanged (AC7 / admin).
    case extract_bearer(conn) do
      {:ok, token} ->
        if jwt_token?(token) do
          call_jwt(conn, token)
        else
          call_opaque(conn, token)
        end

      {:error, :missing_token} ->
        deny(conn, "M_MISSING_TOKEN", "Missing access token")
    end
  end

  @doc """
  True for a compact JWT (contains a "."), false for an opaque Nebu session token (64 hex chars). The ONE
  opaque-vs-JWT decision of the auth layer; the logout handlers use it too (bugfix legacy-logout-per-device).
  """
  @spec jwt_token?(term()) :: boolean()
  def jwt_token?(token), do: is_binary(token) and String.contains?(token, ".")

  # ── Opaque Nebu session token path (oidc-session-refresh) ──────────────────
  # Mirrors the Go middleware WithOpaqueSessionCheck:
  #   * not found           → 401 M_UNKNOWN_TOKEN (no soft_logout)
  #   * soft-revoked        → 401 M_UNKNOWN_TOKEN + soft_logout: true (never deletes, N-1)
  #   * expired             → 401 M_UNKNOWN_TOKEN + soft_logout: true (AC5, spec SHOULD)
  #   * valid               → assign current_user/claims; consume the pending old
  #                           RT(s) the first time the new AT is used (AC4)
  defp call_opaque(conn, token) do
    alias Nebu.Matrix.Session.MatrixSessionStore, as: Store

    case Store.get_by_access_token(token) do
      :error ->
        deny(conn, "M_UNKNOWN_TOKEN", "Invalid or unknown token")

      {:ok, %{revoked_at: %DateTime{}}} ->
        # A hard-revoked AT (logout) is gone (DELETE); a soft-revoked AT (the old
        # half of a rotation, pending OR already consumed) must not authenticate
        # requests. It is ALWAYS answered with soft_logout:true and NEVER deletes
        # anything here (N-1): a legitimate client with an in-flight request just
        # refreshes. Reuse detection happens only on the (bounded) /refresh path:
        # a victim of an active takeover refreshes with its consumed RT -> reuse ->
        # device destroyed (visible end of the takeover); a victim of a passive
        # takeover recovers with its still-pending RT.
        deny_soft_logout(conn, "M_UNKNOWN_TOKEN", "Token has been superseded")

      {:ok, sess} ->
        cond do
          expired?(sess.expires_at) ->
            deny_soft_logout(conn, "M_UNKNOWN_TOKEN", "Token has expired")

          # oidc-session-refresh cycle-2 (Kassandra HIGH, defense-in-depth):
          # re-check is_active per request using the SAME mechanism the JWT path
          # uses (provision/2 — the deactivation check behind the ~60s TTL'd
          # provisioned-user cache). This is NOT an unconditional per-request DB
          # query: a recently-confirmed-good user hits the ETS cache fast path.
          # The PRIMARY fix deletes a deactivated user's matrix_sessions rows
          # immediately, so this path normally never fires; it is the safety net
          # that locks out a deactivated opaque user within the cache TTL even if
          # a row deletion is ever missed, giving parity with the JWT path.
          provision(sess.user_id, %{}) == :deactivated ->
            deny_soft_logout(conn, "M_UNKNOWN_TOKEN", "Account has been deactivated")

          true ->
            # Consume the pending old RT the first time the new AT is used (AC4).
            # Gated on a pending-sibling check so the common path takes no extra write.
            if Store.has_open_grace_window?(token) do
              _ = Store.mark_access_token_used(token)
            end

            conn
            |> assign(:access_token, token)
            |> assign(:current_user, sess.user_id)
            |> assign(:device_id, sess.device_id)
            # story oauth-token-revocation-logout (R15): which API issued this session, decided at
            # AUTHENTICATION time ("legacy" | "oauth"); POST /logout branches on it.
            |> assign(:auth_api, sess.auth_api)
            |> assign(:oidc_claims, %{})
        end
    end
  end

  defp expired?(%DateTime{} = expires_at), do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt
  defp expired?(_), do: true

  defp call_jwt(conn, token) do
    with {:ok, claims} <- verify_token(token),
         :ok <- check_denylist(token, claims) do
      # Use the shared claims→user_id mapping (configured oidc_user_id_claim, not raw sub)
      # so authenticated requests resolve to the SAME identity that POST /login returns.
      user_id = Nebu.Matrix.UserId.from_claims(claims, server_name())

      case provision(user_id, claims) do
        :deactivated ->
          # A deactivated account must not be able to act, even with a still-valid token.
          deny(conn, "M_UNKNOWN_TOKEN", "Account has been deactivated")

        _ ->
          # S2 AC3 / SECURITY G1: resolve the device this JWT was bound to at login
          # from the server-side binding (never from request input). May be nil for a
          # JWT minted before this binding existed, or when the DB is unavailable —
          # downstream then behaves as "no bound device", same as before S2.
          case Nebu.Matrix.Session.DeviceBinding.lookup(token) do
            {:ok, _device_id, true} ->
              # story oauth-token-endpoint (T25 c): the device this JWT is bound to has an OAuth
              # session — OAuth devices know only opaque Nebu tokens (spec 2).
              deny(conn, "M_UNKNOWN_TOKEN", "Access token has been revoked")

            {:ok, device_id, _} ->
              conn
              # Stash the raw token + verified claims so POST /logout can revoke
              # exactly the token that authenticated this request (F-1).
              |> assign(:access_token, token)
              |> assign(:current_user, user_id)
              |> assign(:oidc_claims, claims)
              |> assign(:device_id, device_id)
              |> assign(:auth_api, "legacy")
          end
      end
    else
      {:error, :missing_token} ->
        deny(conn, "M_MISSING_TOKEN", "Missing access token")

      {:error, :expired} ->
        # bugfix-jwt-soft-logout: a naturally-expired JWT is a SOFT logout — the
        # underlying Nebu session (device binding, user, device_id) is still intact
        # server-side, so the client should be told it can recover via refresh/
        # re-auth instead of wiping all local state (E2EE/device data). Mirrors
        # call_opaque/1's already-correct handling of its own expiry case.
        deny_soft_logout(conn, "M_UNKNOWN_TOKEN", "Access token has expired")

      {:error, :revoked} ->
        # F-1: a token denylisted by POST /logout must not be accepted again,
        # even though it still verifies (signature + exp + iss + aud).
        deny(conn, "M_UNKNOWN_TOKEN", "Access token has been revoked")

      {:error, reason} ->
        deny(conn, "M_UNKNOWN_TOKEN", "Invalid access token: #{describe(reason)}")
    end
  end

  # F-1: parity with the Go gateway "Step 2: Denylist check" (auth.go), run only
  # AFTER the token cryptographically verifies — so an attacker cannot flood the
  # denylist by spraying unsigned strings.
  defp check_denylist(token, claims) do
    if Nebu.Web.TokenDenylist.revoked?(claims["jti"], token), do: {:error, :revoked}, else: :ok
  end

  # matrix-api-migration: with the Go gateway removed from the request path, the
  # Elixir stack is now the single auth + provisioning point. The Go gateway used
  # to provision the user row at login (ValidateToken). Here we ensure the user
  # exists on any authenticated request so the FK-bearing write paths (createRoom,
  # join, send) succeed even on the first call after login.
  #
  # Idempotent and best-effort: skipped entirely when Nebu.Repo is not running
  # (pure OidcPlug unit tests, which inject a JWK but no DB). A transient DB error
  # is non-fatal — only an explicitly deactivated account blocks the request.
  #
  # MINOR-3 (cycle 1): validate/4 + upsert_profile is a DB round-trip on EVERY
  # authenticated request, including the /sync long-poll hot path (AC2). We gate
  # it with a best-effort, race-tolerant ETS "already provisioned" cache so the
  # full validate+upsert runs at most once per user per TTL window. A brand-new
  # user is still provisioned on first sight (cache miss). A deactivated account
  # is NOT cached: it must still be re-checked on every request — and a user is
  # only cached after a successful validate (so a transient DB error leaves them
  # uncached and retried next time).
  #
  # MINOR-6 (cycle 2): the cache entry carries a monotonic timestamp and is
  # treated as a MISS once it is older than @provision_cache_ttl_ms (60s,
  # matching the Go gateway's makeStatusChecker is_active/status TTL in
  # gateway/internal/middleware/auth.go). So provisioning AND the deactivation
  # re-check happen at most once per TTL window per user — a user deactivated
  # mid-session is re-validated and blocked within 60s (worst case), preserving
  # Go parity instead of being accepted for the whole node lifetime.
  defp provision(user_id, claims) do
    cond do
      not running?(Nebu.Repo) ->
        :ok

      provisioned?(user_id) ->
        # Validated + profile-upserted within the last TTL window — skip the DB
        # round-trip. (A deactivation is never cached, and the entry expires
        # after the TTL, so this fast path only ever covers a recently
        # confirmed-good account.)
        :ok

      true ->
        do_provision(user_id, claims)
    end
  end

  defp do_provision(user_id, claims) do
    display_name = claims["preferred_username"] || claims["name"] || ""
    email = claims["email"] || ""

    # MAJOR-1: warn operators when OIDC claims are absent. Scopes are configured via
    # the IdP client + bootstrap wizard claim mapping (ADR-022), not env vars. Only
    # logged on first provisioning (cache miss), not every request.
    if email == "" do
      Logger.warning(
        "OIDC: email claim absent for #{user_id} — ensure the IdP client grants the profile/email scopes if email is required"
      )
    end

    if display_name == "" do
      Logger.warning(
        "OIDC: preferred_username/name claim absent for #{user_id} — ensure the IdP client grants the profile scope if display name is required"
      )
    end

    case Nebu.Matrix.Session.TokenValidator.validate(user_id, "user", display_name, email) do
      {:ok, _user} ->
        # Mirror the Go login flow (Server.validate_token): upsert the profile
        # row so GET /profile/{userId} returns 200 for provisioned users.
        dn = if display_name == "", do: nil, else: display_name
        _ = Nebu.Matrix.Profile.DB.upsert_profile(user_id, dn, nil)
        mark_provisioned(user_id)
        :ok

      {:error, :deactivated} ->
        :deactivated

      {:error, _reason} ->
        :ok
    end
  end

  # ── Provisioning cache (MINOR-3, TTL added in MINOR-6) ─────────────────────
  # A named ETS set of {user_id, cached_at_monotonic_ms} tuples. Best-effort and
  # race-tolerant: a concurrent double-insert is harmless (validate/upsert are
  # idempotent), and a missing table (table not yet created in a bare unit test)
  # just means every request provisions — correct, only slower.
  #
  # An entry older than the TTL is treated as a cache MISS, forcing a fresh
  # validate (which re-checks deactivation) and a refreshed timestamp on the
  # next success. The age is measured with a MONOTONIC clock so a wall-clock
  # adjustment (NTP step, manual change) can never make a stale entry look
  # fresh — or vice versa.
  @provisioned_table :nebu_http_provisioned_users

  # Default TTL: 60s, matching the Go gateway status-check cache
  # (gateway/internal/middleware/auth.go, makeStatusChecker). Read at runtime
  # from Application env so deployments — and tests — can tune it (a test sets
  # it to 0 to force every entry to read as expired).
  @provision_cache_ttl_ms 60_000

  defp provision_cache_ttl_ms do
    Application.get_env(:nebu_http, :provision_cache_ttl_ms, @provision_cache_ttl_ms)
  end

  defp provisioned?(user_id) do
    ensure_table()

    case :ets.lookup(@provisioned_table, user_id) do
      [{^user_id, cached_at}] ->
        now_monotonic_ms() - cached_at < provision_cache_ttl_ms()

      _ ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp mark_provisioned(user_id) do
    ensure_table()
    :ets.insert(@provisioned_table, {user_id, now_monotonic_ms()})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp now_monotonic_ms, do: System.monotonic_time(:millisecond)

  # Lazily create the public, named set on first use. Wrapped because two
  # processes can race to create it — the loser gets ArgumentError, which is
  # fine (the table already exists).
  defp ensure_table do
    case :ets.whereis(@provisioned_table) do
      :undefined ->
        try do
          :ets.new(@provisioned_table, [:set, :public, :named_table, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end

  defp running?(name), do: Process.whereis(name) != nil

  # ── Bearer extraction ───────────────────────────────────────────────────

  defp extract_bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when token != "" -> {:ok, token}
      _ -> {:error, :missing_token}
    end
  end

  # ── Token verification ──────────────────────────────────────────────────
  #
  # Public so the unauthenticated login handler (POST /_matrix/client/v3/login)
  # can verify an OIDC token presented in the request body and reuse the exact
  # same signature/alg/iss/aud/exp/sub checks (no divergent auth path).

  @doc """
  Verifies a compact JWS Bearer token against the configured JWKS keys.

  Returns `{:ok, claims}` on success or `{:error, reason}` on any failure
  (alg not allowed, unknown kid, bad signature, expired, wrong iss/aud,
  missing sub, malformed token, iss/aud not configured).

  `opts` may carry `:audience` to override the expected `aud` claim — used by the
  admin OIDC login (Nebu.Admin.Auth). Under ADR-022 there is a SINGLE OIDC client, so
  the admin ID token's `aud` is that client's id; the override lets admin login validate
  against `client_id` while Matrix Bearer validation uses the configured
  `server_config` audience. All other checks (alg allowlist, JWKS signature,
  fail-closed iss, exp, sub) are IDENTICAL — there is still exactly one verification
  code path. The override is still fail-closed:
  a nil/empty override yields `:audience_not_configured`, and a token whose aud does
  not match is rejected.

  `opts` may also carry `:issuer` and `:jwks` overrides — used ONLY by the bootstrap
  operator-login callback (Nebu.Admin.Auth bootstrap mode, story
  oidc-bootstrap-only-e2e-regressions). During the bootstrap wizard the OIDC config
  lives in the `bootstrap_draft`, NOT yet in `server_config`, so the global
  `OidcConfig`/`JwksCache` are still empty. These overrides let the bootstrap callback
  verify the operator ID token using the DRAFT's issuer + JWKS (fetched locally from the
  draft's `oidc_jwks_uri`/`oidc_issuer`) WITHOUT warming the global caches — preserving
  the ADR-022 fail-closed invariant that the Matrix API rejects every Bearer token until
  bootstrap completes. Both overrides are fail-closed exactly like `:audience`:

    * `:issuer` — when a non-empty binary, the token `iss` is checked against the
      OVERRIDE instead of the global `OidcConfig` issuer. A nil/empty override with no
      global issuer configured still yields `:issuer_not_configured`; a token whose `iss`
      does not match yields `:bad_issuer`.
    * `:jwks` — when a non-nil list, signing-key selection uses THIS key list instead of
      the global `:oidc_jwks` app-env / `JwksCache.keys()`. An empty list still yields
      `:no_keys`. When absent/nil, key resolution is UNCHANGED.

  All other checks (alg allowlist, signature, exp, sub) are IDENTICAL — there is still
  exactly one verification code path, and only the bootstrap callback passes these opts.
  """
  @spec verify_token(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify_token(token, opts \\ []) do
    audience_override = Keyword.get(opts, :audience)
    issuer_override = Keyword.get(opts, :issuer)
    jwks_override = Keyword.get(opts, :jwks)

    with {:ok, header} <- peek_header(token),
         :ok <- check_alg(header["alg"]),
         {:ok, jwk} <- select_key(header["kid"], jwks_override),
         {:ok, %{verified?: true, claims: claims}} <- assent_verify(token, jwk),
         :ok <- check_exp(claims),
         :ok <- check_issuer(claims, issuer_override),
         :ok <- check_audience(claims, audience_override),
         :ok <- check_subject(claims) do
      {:ok, claims}
    else
      {:ok, %{verified?: false}} -> {:error, :bad_signature}
      {:error, _} = err -> err
      other -> {:error, {:unexpected, other}}
    end
  end

  # MEDIUM-2: the alg MUST be an explicit asymmetric algorithm. Reject `none`
  # and HMAC (HS*) before doing any key selection or signature verification.
  defp check_alg(alg) when is_binary(alg) do
    if alg in @allowed_algs, do: :ok, else: {:error, :unexpected_alg}
  end

  defp check_alg(_), do: {:error, :unexpected_alg}

  # Peek the protected header (without verifying) to obtain alg + kid.
  defp peek_header(token) do
    try do
      {_, header} = token |> JOSE.JWT.peek_protected() |> JOSE.JWS.to_map()
      {:ok, header}
    rescue
      _ -> {:error, :malformed_token}
    catch
      _, _ -> {:error, :malformed_token}
    end
  end

  # `jwks_override` (a list of JWK maps) is passed ONLY by the bootstrap callback so
  # key selection uses the draft-sourced keys instead of the global cache. When it is
  # nil the global resolution (available_keys/0) is used — normal request path unchanged.
  defp select_key(kid, jwks_override) do
    keys = if is_list(jwks_override), do: jwks_override, else: available_keys()

    cond do
      keys == [] ->
        {:error, :no_keys}

      kid == nil ->
        # No kid in header: only unambiguous when there is exactly one key.
        case keys do
          [single] -> {:ok, single}
          _ -> {:error, :unknown_kid}
        end

      true ->
        case Enum.find(keys, fn k -> k["kid"] == kid end) do
          nil -> {:error, :unknown_kid}
          jwk -> {:ok, jwk}
        end
    end
  end

  defp assent_verify(token, jwk) do
    Assent.JWTAdapter.verify(token, jwk, [])
  rescue
    _ -> {:error, :verify_failed}
  catch
    _, _ -> {:error, :verify_failed}
  end

  defp check_exp(%{"exp" => exp}) when is_integer(exp) do
    if exp <= System.system_time(:second), do: {:error, :expired}, else: :ok
  end

  # A token with no (or a non-integer) `exp` claim never expires — reject it
  # rather than treating an absent expiry as valid.
  defp check_exp(_), do: {:error, :missing_exp}

  # The `sub` claim is the Matrix user identity. A missing/empty/non-string sub
  # would build a nonsense ID like "@:server" — reject instead of accepting it.
  defp check_subject(%{"sub" => sub}) when is_binary(sub) and sub != "", do: :ok
  defp check_subject(_), do: {:error, :missing_subject}

  # MEDIUM-3: fail CLOSED. A missing issuer config means we cannot validate the
  # token's origin, so we reject rather than letting it through.
  #
  # An explicit `override` (bootstrap callback) takes precedence over the global
  # OidcConfig issuer; nil/empty either way → rejected (never fails open).
  defp check_issuer(claims, override) do
    case issuer_or_nil(override) || oidc_issuer() do
      nil -> {:error, :issuer_not_configured}
      "" -> {:error, :issuer_not_configured}
      issuer -> if claims["iss"] == issuer, do: :ok, else: {:error, :bad_issuer}
    end
  end

  defp issuer_or_nil(override) when is_binary(override) and override != "", do: override
  defp issuer_or_nil(_), do: nil

  # MEDIUM-3: fail CLOSED for audience as well. An explicit override (admin login)
  # takes precedence over the configured Matrix audience; nil/empty either way →
  # rejected (never fails open).
  defp check_audience(claims, override) do
    case override || oidc_audience() do
      nil -> {:error, :audience_not_configured}
      "" -> {:error, :audience_not_configured}
      audience -> if aud_matches?(claims["aud"], audience), do: :ok, else: {:error, :bad_audience}
    end
  end

  # The "aud" claim may be a string or a list of strings.
  defp aud_matches?(aud, audience) when is_binary(aud), do: aud == audience
  defp aud_matches?(aud, audience) when is_list(aud), do: audience in aud
  defp aud_matches?(_, _), do: false

  # ── Key source + config ─────────────────────────────────────────────────

  defp available_keys do
    case Application.get_env(:nebu_http, :oidc_jwks) do
      keys when is_list(keys) -> keys
      _ -> Nebu.Web.JwksCache.keys()
    end
  end

  defp server_name, do: Application.get_env(:nebu_http, :server_name, "localhost")

  # oidc-bootstrap-only-config (ADR-022): issuer/audience are resolved SOLELY from
  # server_config via the OidcConfig DB-backed cache. There is no environment-variable
  # config path. Fail-closed invariant (MEDIUM-3) is preserved: when server_config has
  # no issuer/audience, OidcConfig.get/0 returns nil and check_issuer/check_audience
  # reject every token ({:error, :*_not_configured}).
  defp oidc_issuer, do: Nebu.Web.OidcConfig.get().issuer

  defp oidc_audience, do: Nebu.Web.OidcConfig.get().audience

  # ── Failure response ────────────────────────────────────────────────────

  defp deny(conn, errcode, error) do
    body = Jason.encode!(%{"errcode" => errcode, "error" => error})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end

  # AC5 (spec SHOULD): a token rejection that still leaves the underlying Nebu
  # session (device binding, user, device_id) intact returns soft_logout: true so
  # the client knows it can recover by refreshing/re-authing (vs. a hard logout
  # that requires wiping local state). Callers: opaque-session expiry,
  # opaque-session deactivated-account re-check, and JWT-fallback expiry
  # (call_jwt/2's :expired branch).
  defp deny_soft_logout(conn, errcode, error) do
    body = Jason.encode!(%{"errcode" => errcode, "error" => error, "soft_logout" => true})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end

  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason), do: inspect(reason)
end
