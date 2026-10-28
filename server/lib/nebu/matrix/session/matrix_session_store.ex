defmodule Nebu.Matrix.Session.MatrixSessionStore do
  @moduledoc """
  Opaque Matrix access/refresh-token session store (oidc-session-refresh).

  Plain module, inline parameterised SQL via `Nebu.Repo` (ADR-018 — no Ecto
  schema, no Repository/Service layer). Backs the `matrix_sessions` table that
  exists in the canonical schema (`server/priv/migrations/000001_init.up.sql`);
  migration 000038 (token-hashing-matrix-sessions) replaced the plaintext token
  columns by their SHA-256 hashes.

  ## Hashed storage (token-hashing-matrix-sessions)

  The table never holds a plaintext access/refresh token: its keys are
  `access_token_hash` (PRIMARY KEY) and `refresh_token_hash` (UNIQUE NOT NULL), the
  lowercase hex SHA-256 of the token (`hash_token/1`, the ONLY place a token is
  hashed). Both tokens are 256-bit random values, so an unsalted hash is enough.
  The public API keeps taking PLAINTEXT tokens (the value the client presents);
  every lookup/update/delete hashes it first and compares by indexed equality.
  Session maps returned by the store carry only `:access_token_hash` /
  `:refresh_token_hash` (a token is never read back). Callers that know a row only
  by its hash (`RefreshWorker`, the `/refresh` rotation) use the `*_by_hash`
  variants or the `:old_access_token_hash` rotate param.

  Ports the Go reference `gateway/internal/db/matrix_session_store.go`.

  ## What it stores

  When a Matrix client logs in with `refresh_token: true` and an OIDC refresh
  token was captured during SSO, login mints an opaque access token + refresh
  token (32 random bytes → 64 lowercase hex chars, no `.`, so distinguishable
  from a JWT) and persists them here together with the AES-256-GCM-encrypted OIDC
  refresh token and a Nebu-controlled `expires_at = min(oidc_exp, now + 8h)`.

  ## Token rotation + "valid until used" (Matrix CS API v1.18 §refreshing-access-tokens)

  Spec rule (legacy `POST /refresh`): "the old refresh token remains valid until
  the new access token or refresh token is used, at which point the old refresh
  token is revoked". There is NO fixed time window in the spec.

  `POST /refresh` calls `rotate_tokens/1`, which in a SINGLE transaction:

    * takes the `devices`-row lock of the old row's device FIRST (gate x, bugfix
      legacy-logout-per-device, LL9; lock order devices -> matrix_sessions, the same lock every
      teardown takes, so a rotation and a device teardown serialise and no working token survives
      a deleted device),
    * soft-revokes the old row (`revoked_at = NOW()`, `grace_until = NULL`), and
    * inserts the new AT/RT row, carrying over the encrypted OIDC RT.

  A soft-revoked row with `grace_until IS NULL` is PENDING: its refresh token is
  still redeemable (a client that lost the response retries with it, and is served
  by rotating the device's active row again) for as long as the device's active
  row has not expired (the session's own `expires_at` is the upper bound). The
  row is CONSUMED (`grace_until` set to a past/now timestamp) the first time the
  new access token authenticates a request (`mark_access_token_used/1`) or the
  new refresh token is redeemed (`consume_pending_siblings` in `rotate_tokens/1`).
  Presenting a consumed refresh token is token reuse (see `resolve_refresh_token/1`).

  PENDING vs CONSUMED is decided ONLY by `grace_until IS NULL` / `IS NOT NULL`,
  never by comparing it with `NOW()`: in Postgres `NOW()` is the transaction START,
  so a time comparison could read a token consumed by a concurrent transaction as
  still pending. The null test is re-evaluated by Postgres after a row-lock wait,
  so it is race-free. (Legacy rows carrying a future `grace_until` from the old
  fixed-window design count as consumed — the safe direction.) Multi-row sibling
  updates lock their rows in `access_token_hash` order to rule out lock-order deadlocks.

  The background `RefreshWorker` never rotates: it extends the active row IN PLACE
  (`extend_in_place/3`), so the tokens the client holds stay valid.

  ## Legacy rows only (story oauth-token-endpoint, T27)

  Since migration 000042 `matrix_sessions` also holds OAuth sessions (`auth_api = 'oauth'`, issued
  by `POST /oauth2/token`, managed by `Nebu.Matrix.Session.OAuthSessionStore`). The refresh /
  extension machinery of this module (`resolve_refresh_token/1`, the replay sibling lookup,
  `rotate_tokens/1`'s sibling updates, `extend_in_place*/3`, `store_rotated_oidc_rt/3`) acts on
  `auth_api = 'legacy'` rows ONLY: an OAuth refresh token is unknown to `POST /refresh`, and the
  `RefreshWorker` never extends an OAuth row. `mark_access_token_used/1` / `has_open_grace_window?/1`
  consume pending siblings of the SAME `auth_api` (so the OidcPlug Refresh-Retry path works for both).
  Lookups by access token (`get_by_access_token/1`, `get_auth_context/1`) and the delete paths
  (device deletion, deactivation) cover both kinds. The legacy `POST /logout` no longer uses
  `revoke/1`: it ends the presented credential's device through `Nebu.Matrix.legacy_logout_device/1`
  (locked per-device teardown, bugfix legacy-logout-per-device). `cleanup_expired/0` uses
  `COALESCE(session_expires_at, expires_at)` (an OAuth row's `expires_at` is only the 15-minute
  access-token expiry).

  All token values are opaque secrets; this module never logs them.
  """

  require Logger

  @doc """
  Generates an opaque token: 32 random bytes as 64 lowercase hex chars.
  Contains no `.`, so `OidcPlug` can distinguish it from a JWT. Mirrors the Go
  `generateOpaqueToken()`.
  """
  @spec generate_opaque_token() :: String.t()
  def generate_opaque_token, do: :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)

  @doc """
  The single hashing seam: lowercase hex SHA-256 of a token string. Tokens are
  256-bit random values, so no salt/KDF is needed. Raises for non-binary input.
  """
  @spec hash_token(String.t()) :: String.t()
  def hash_token(token) when is_binary(token),
    do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  @doc """
  Inserts a new session row.

  `params` keys: `:access_token`, `:refresh_token`, `:user_id`, `:device_id`,
  `:expires_at` (a `DateTime`), and optional `:oidc_refresh_token` (already
  AES-256-GCM encrypted; `nil` when no OIDC RT was obtained).
  """
  @spec create(map()) :: :ok
  def create(%{
        access_token: at,
        refresh_token: rt,
        user_id: user_id,
        device_id: device_id,
        expires_at: expires_at
      } = params) do
    enc_oidc_rt = Map.get(params, :oidc_refresh_token)
    # S3: auth_time (unix seconds) is the user's LAST FRESH authentication time,
    # taken at login from the id_token's auth_time/iat claim. The UIA freshness gate
    # compares now - auth_time. nil → treated as "stale" (always challenge).
    auth_time = Map.get(params, :auth_time)

    {:ok, _} =
      query(
        """
        INSERT INTO matrix_sessions
          (access_token_hash, refresh_token_hash, oidc_refresh_token, user_id, device_id, expires_at, auth_time, created_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())
        """,
        [hash_token(at), hash_token(rt), enc_oidc_rt, user_id, device_id, expires_at, auth_time]
      )

    :ok
  end

  @doc """
  Reads the auth context for the UIA freshness gate (S3) by opaque access token:
  `{:ok, %{user_id, device_id, auth_time}}` (auth_time is unix seconds or nil) or
  `:error`. Read-path: never raises.
  """
  @spec get_auth_context(String.t()) :: {:ok, map()} | :error
  def get_auth_context(access_token) when is_binary(access_token) do
    case safe_query(
           "SELECT user_id, device_id, auth_time FROM matrix_sessions WHERE access_token_hash = $1",
           [hash_token(access_token)]
         ) do
      {:ok, %{rows: [[user_id, device_id, auth_time]]}} ->
        {:ok, %{user_id: user_id, device_id: device_id, auth_time: auth_time}}

      _ ->
        :error
    end
  end

  @doc """
  Looks up a session by opaque access token. Returns `{:ok, session}` or `:error`.

  The session map exposes `:access_token_hash`, `:refresh_token_hash`, `:oidc_refresh_token`
  (encrypted, may be `nil`), `:user_id`, `:device_id`, `:expires_at`,
  `:revoked_at`, `:grace_until`, `:auth_api` (`"legacy"` | `"oauth"`). The expiry decision is made by the caller
  (`OidcPlug`) so the AC5 `soft_logout` path can distinguish expired from absent.
  """
  @spec get_by_access_token(String.t()) :: {:ok, map()} | :error
  def get_by_access_token(access_token) when is_binary(access_token),
    do: get_by_access_token_hash(hash_token(access_token))

  @doc false
  # INTERNAL - pass-the-hash warning: only for hash values read from the DB (RefreshWorker,
  # HttpPublic.rotate_attempt). NEVER pass a client-supplied value here: a leaked hash
  # must not act as a credential. Public API takes plaintext tokens only.
  @spec get_by_access_token_hash(String.t()) :: {:ok, map()} | :error
  def get_by_access_token_hash(access_token_hash) when is_binary(access_token_hash) do
    case safe_query(select_sql("access_token_hash = $1"), [access_token_hash]) do
      {:ok, %{rows: [row]}} -> {:ok, row_to_session(row)}
      _ -> :error
    end
  end

  @doc """
  Classifies a presented refresh token for `POST /refresh`.

    * `{:ok, active_session, :current}` — the token is the device's active RT.
    * `{:ok, active_session, :replay}` — the token was rotated away but is still
      PENDING (new tokens unused, session not expired): the caller serves it by
      rotating the device's ACTIVE row (returned, so its — possibly newer — OIDC
      refresh token is the one redeemed at the IdP).
    * `{:consumed, session}` — rotated away AND already consumed, the consumed row
      younger than the session TTL ceiling, and the device still has an active
      row (redeemable, same as `:current`, even if its AT has expired): token reuse (bounded, F-3).
    * `:error` — unknown, hard-revoked, pending but the session expired, or consumed
      but outside the reuse bound (old token / dead device: plain 401, no deletion).
    * `{:error, :unavailable}` — the DB could not be queried (transient).
  """
  @spec resolve_refresh_token(String.t()) ::
          {:ok, map(), :current | :replay} | {:consumed, map()} | :error | {:error, :unavailable}
  def resolve_refresh_token(refresh_token) when is_binary(refresh_token) do
    sql =
      """
      SELECT access_token_hash, refresh_token_hash, oidc_refresh_token, user_id, device_id,
             expires_at, revoked_at, grace_until, auth_api,
             (grace_until IS NOT NULL),
             (created_at + ($2::bigint * INTERVAL '1 second') > NOW()),
             EXISTS(SELECT 1 FROM matrix_sessions a
                     WHERE a.user_id = matrix_sessions.user_id
                       AND a.device_id = matrix_sessions.device_id
                       AND a.auth_api = 'legacy'
                       AND a.revoked_at IS NULL)
        FROM matrix_sessions
       WHERE refresh_token_hash = $1 AND auth_api = 'legacy'
      """

    case safe_query(sql, [hash_token(refresh_token), Nebu.Web.SessionConfig.matrix_session_ttl_seconds()]) do
      {:ok, %{rows: []}} ->
        :error

      {:ok, %{rows: [row]}} ->
        # Trap 3 (story oauth-token-endpoint): the 9 session columns (incl. auth_api) come first,
        # the computed columns follow at index 9.
        {consumed?, row} = List.pop_at(row, 9)
        {young?, row} = List.pop_at(row, 9)
        {has_active?, row} = List.pop_at(row, 9)
        sess = row_to_session(row)

        cond do
          is_nil(sess.revoked_at) -> {:ok, sess, :current}
          # F-3: reuse detection is bounded. Only a YOUNG consumed row (created within
          # the session TTL ceiling) of a device that still has an active (redeemable) row counts
          # as reuse; an old leaked RT is a plain 401 and must not log the device out.
          consumed? and young? and has_active? -> {:consumed, sess}
          consumed? -> :error
          true -> active_sibling(sess)
        end

      _ ->
        {:error, :unavailable}
    end
  end

  defp active_sibling(%{user_id: user_id, device_id: device_id}) do
    case safe_query(
           select_sql("user_id = $1 AND device_id = $2 AND auth_api = 'legacy' AND revoked_at IS NULL AND expires_at > NOW()"),
           [user_id, device_id]
         ) do
      {:ok, %{rows: [row | _]}} -> {:ok, row_to_session(row), :replay}
      {:ok, %{rows: []}} -> :error
      _ -> {:error, :unavailable}
    end
  end

  @doc """
  Atomically rotates a session's AT+RT pair (single transaction).

  Soft-revokes the old row (`revoked_at = NOW()`, `grace_until = NULL` = pending:
  the old RT stays valid until the new tokens are used) and inserts the new row,
  carrying over the encrypted OIDC RT unless `:new_oidc_refresh_token` supplies a
  fresh one (provider-rotated). Returns `:error` if the old access token is
  unknown / already revoked (the caller maps that to a re-resolve or 401), and
  `{:error, :consumed}` when `:replay_refresh_token` is no longer pending.

  `params`: `:old_access_token` (plaintext) or, INTERNAL ONLY, `:old_access_token_hash`
  (for the `/refresh` rotation, which holds a session map read from the DB; never a
  client-supplied value - pass-the-hash). Passing BOTH keys raises `ArgumentError`
  (callers map that to a 503 via `safe_rotate`); passing neither is also rejected.
  `:new_access_token`, `:new_refresh_token`,
  `:new_expires_at` (DateTime), optional `:new_oidc_refresh_token` (already
  AES-256-GCM encrypted).

  `:consume_pending_siblings` (default `false`): set when the client redeemed the
  device's CURRENT refresh token — that proves it holds the newest tokens, so every
  older pending refresh token of the device is consumed in the same transaction.
  Not set when serving a replay of a pending (old) refresh token.

  `:replay_refresh_token` (optional): the pending (rotated-away) refresh token the
  client presented. Its state is re-validated INSIDE this transaction (row locked
  `FOR UPDATE`, after the active row was claimed — same lock order as every other
  writer), because the IdP round trip between `resolve_refresh_token/1` and this
  call can take seconds, during which the legitimate client may have used its new
  access token and thereby consumed the presented token. If it is no longer pending
  the transaction rolls back and `{:error, :consumed}` is returned (token reuse).
  """
  @spec rotate_tokens(map()) :: :ok | :error | {:error, :consumed}
  def rotate_tokens(%{
        new_access_token: new_at,
        new_refresh_token: new_rt,
        new_expires_at: new_expires_at
      } = params) do
    new_oidc_rt = Map.get(params, :new_oidc_refresh_token)
    old_h = old_access_token_hash(params)
    new_at_h = hash_token(new_at)
    new_rt_h = hash_token(new_rt)

    txn =
      Nebu.Repo.transaction(fn ->
        # 0. Gate x (bugfix legacy-logout-per-device, LL9): take the devices-row lock of the
        #    old row's device BEFORE the soft-revoke UPDATE, exactly like the OAuth rotation and
        #    every teardown (lock order devices -> matrix_sessions). A teardown and a rotation of
        #    the same device therefore serialise: when the teardown wins, the UPDATE below matches
        #    0 rows (`:not_found`, the caller re-resolves and answers 401); when the rotation wins,
        #    the teardown's later DELETE also removes the new row. A missing devices row locks
        #    nothing. The row is read WITHOUT a lock (no devices-after-matrix_sessions inversion).
        case query(
               "SELECT user_id, device_id FROM matrix_sessions WHERE access_token_hash = $1 AND auth_api = 'legacy'",
               [old_h]
             ) do
          {:ok, %{rows: []}} ->
            Nebu.Repo.rollback(:not_found)

          {:ok, %{rows: [[lock_user_id, lock_device_id] | _]}} ->
            {:ok, _} =
              query("SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [lock_user_id, lock_device_id])
        end

        # 1. Soft-revoke the old row (atomic single-row statement; exactly one
        #    concurrent rotation of the same row wins). grace_until stays NULL:
        #    the old RT is PENDING until the new tokens are used.
        case query(
               """
               UPDATE matrix_sessions
                  SET revoked_at = NOW(), grace_until = NULL
                WHERE access_token_hash = $1 AND revoked_at IS NULL AND auth_api = 'legacy'
               """,
               [old_h]
             ) do
          {:ok, %{num_rows: 0}} ->
            Nebu.Repo.rollback(:not_found)

          {:ok, _} ->
            # 1b. M1 (TOCTOU): a replayed pending RT must STILL be pending now.
            #     FOR UPDATE serialises against a concurrent mark_access_token_used/1.
            case Map.get(params, :replay_refresh_token) do
              nil ->
                :ok

              replay_rt ->
                case query(
                       """
                       SELECT 1 FROM matrix_sessions
                        WHERE refresh_token_hash = $1
                          AND auth_api = 'legacy'
                          AND revoked_at IS NOT NULL
                          AND grace_until IS NULL
                          FOR UPDATE
                       """,
                       [hash_token(replay_rt)]
                     ) do
                  {:ok, %{num_rows: 0}} -> Nebu.Repo.rollback(:consumed)
                  {:ok, _} -> :ok
                end
            end

            # 2. Read the old row to copy user_id/device_id, (default) the OIDC RT,
            #    and — S3 — the auth_time VERBATIM. A refresh is NOT a fresh
            #    authentication, so it must carry over the original auth_time
            #    unchanged; resetting it here would let a refresh defeat the UIA
            #    freshness gate (story Dev Notes).
            {:ok, %{rows: [[user_id, device_id, old_enc_oidc_rt, old_auth_time]]}} =
              query(
                "SELECT user_id, device_id, oidc_refresh_token, auth_time FROM matrix_sessions WHERE access_token_hash = $1",
                [old_h]
              )

            enc_oidc_rt = new_oidc_rt || old_enc_oidc_rt

            if Map.get(params, :consume_pending_siblings, false) do
              {:ok, _} =
                query(
                  """
                  UPDATE matrix_sessions
                     SET grace_until = NOW()
                   WHERE access_token_hash IN (
                           SELECT access_token_hash FROM matrix_sessions
                            WHERE user_id = $1 AND device_id = $2
                              AND auth_api = 'legacy'
                              AND access_token_hash != $3
                              AND revoked_at IS NOT NULL
                              AND grace_until IS NULL
                            ORDER BY access_token_hash
                              FOR UPDATE)
                  """,
                  [user_id, device_id, old_h]
                )
            end

            # 3. Insert the new row, carrying auth_time over unchanged.
            {:ok, _} =
              query(
                """
                INSERT INTO matrix_sessions
                  (access_token_hash, refresh_token_hash, oidc_refresh_token, user_id, device_id, expires_at, auth_time, created_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())
                """,
                [new_at_h, new_rt_h, enc_oidc_rt, user_id, device_id, new_expires_at, old_auth_time]
              )

            :ok
        end
      end)

    case txn do
      {:ok, :ok} -> :ok
      {:error, :not_found} -> :error
      {:error, :consumed} -> {:error, :consumed}
    end
  end

  defp old_access_token_hash(%{old_access_token: _, old_access_token_hash: _}),
    do: raise(ArgumentError, "rotate_tokens/1: pass either :old_access_token or :old_access_token_hash, not both")

  defp old_access_token_hash(%{old_access_token_hash: h}) when is_binary(h), do: h
  defp old_access_token_hash(%{old_access_token: at}) when is_binary(at), do: hash_token(at)

  defp old_access_token_hash(_),
    do: raise(ArgumentError, "rotate_tokens/1: :old_access_token or :old_access_token_hash required")

  @doc """
  Consumes every PENDING soft-revoked sibling row of the same user+device the
  first time `access_token` is used (the old RT is invalid once the new AT is
  used). Idempotent: a no-op when no pending sibling exists, and harmless on an
  unknown token.
  """
  @spec mark_access_token_used(String.t()) :: :ok
  def mark_access_token_used(access_token) when is_binary(access_token) do
    at_h = hash_token(access_token)

    case query(
           "SELECT user_id, device_id, auth_api FROM matrix_sessions WHERE access_token_hash = $1",
           [at_h]
         ) do
      {:ok, %{rows: [[user_id, device_id, auth_api]]}} ->
        # T27: only siblings of the SAME auth_api (an OAuth AT consumes pending OAuth RTs, a
        # legacy AT pending legacy RTs).
        # G3-1 L-2: best effort on a per-request path. `FOR UPDATE SKIP LOCKED` skips sibling rows that another
        # transaction holds (a client revoke that deleted them keeps them locked until its commit) instead of waiting
        # on them; a skipped sibling keeps its pending grace window and is handled by the next request. A failing
        # statement is tolerated (no raise: it must not fail the request it rides on).
        _ =
          query(
            """
            UPDATE matrix_sessions
               SET grace_until = NOW()
             WHERE access_token_hash IN (
                     SELECT access_token_hash FROM matrix_sessions
                      WHERE user_id = $1 AND device_id = $2
                        AND auth_api = $4
                        AND revoked_at IS NOT NULL
                        AND grace_until IS NULL
                        AND access_token_hash != $3
                      ORDER BY access_token_hash
                        FOR UPDATE SKIP LOCKED)
            """,
            [user_id, device_id, at_h, auth_api]
          )

        :ok

      _ ->
        # Unknown AT — nothing to expire.
        :ok
    end
  end

  @doc """
  Indicates whether `access_token` has a PENDING soft-revoked sibling (same
  user+device), folded into one query. Lets `OidcPlug` skip
  `mark_access_token_used/1` — and its write — on the common request path where
  no rotation happened. Only meaningful when the AT itself is not revoked.
  """
  @spec has_open_grace_window?(String.t()) :: boolean()
  def has_open_grace_window?(access_token) when is_binary(access_token) do
    case safe_query(
           """
           SELECT EXISTS(
             SELECT 1 FROM matrix_sessions s2
              WHERE s2.user_id = m.user_id
                AND s2.device_id = m.device_id
                AND s2.auth_api = m.auth_api
                AND s2.access_token_hash != m.access_token_hash
                AND s2.revoked_at IS NOT NULL
                AND s2.grace_until IS NULL
           )
           FROM matrix_sessions m
           WHERE m.access_token_hash = $1 AND m.revoked_at IS NULL
           """,
           [hash_token(access_token)]
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  @doc """
  Extends the ACTIVE row `access_token` IN PLACE (background `RefreshWorker`):
  sets `expires_at` and, when the IdP rotated it, the encrypted OIDC refresh token
  (`nil` keeps the stored blob). Access and refresh token are never touched, so the
  tokens the client holds stay valid. Atomic single-row statement guarded by
  `revoked_at IS NULL`; returns `:error` when the row is gone or no longer active.

  F-1: the extension is capped at `created_at + matrix_session_ttl_seconds` (absolute
  bound from the issuance of THIS row). A client `/refresh` creates a new row with a
  fresh `created_at`, so the cap only bounds devices that never refresh themselves.
  At the cap the worker simply stops extending: the row expires normally and the
  client gets the `soft_logout` path. Strictly extending: `GREATEST(expires_at, ...)`
  guarantees the value is never shortened (also for rows that earlier worker versions
  extended beyond the cap).
  """
  @spec extend_in_place(String.t(), DateTime.t(), String.t() | nil) :: :ok | :error
  def extend_in_place(access_token, %DateTime{} = new_expires_at, enc_oidc_rt)
      when is_binary(access_token),
      do: extend_in_place_by_hash(hash_token(access_token), new_expires_at, enc_oidc_rt)

  @doc false
  # INTERNAL - pass-the-hash warning: only for hash values read from the DB (RefreshWorker,
  # HttpPublic.rotate_attempt). NEVER pass a client-supplied value here: a leaked hash
  # must not act as a credential. Public API takes plaintext tokens only.
  @spec extend_in_place_by_hash(String.t(), DateTime.t(), String.t() | nil) :: :ok | :error
  def extend_in_place_by_hash(access_token_hash, %DateTime{} = new_expires_at, enc_oidc_rt)
      when is_binary(access_token_hash) do
    case query(
           """
           UPDATE matrix_sessions
              SET expires_at = GREATEST(expires_at, LEAST($2, created_at + ($4::bigint * INTERVAL '1 second'))),
                  oidc_refresh_token = COALESCE($3, oidc_refresh_token)
            WHERE access_token_hash = $1 AND revoked_at IS NULL AND auth_api = 'legacy'
           """,
           [
             access_token_hash,
             new_expires_at,
             enc_oidc_rt,
             Nebu.Web.SessionConfig.matrix_session_ttl_seconds()
           ]
         ) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, _} -> :error
    end
  end

  @doc """
  Stores a provider-rotated encrypted OIDC refresh token on the CURRENT active row
  of `(user_id, device_id)`. Used by the `RefreshWorker` when `extend_in_place/3`
  lost a race against a client `/refresh` (the row it extended was rotated away):
  the IdP already invalidated the previous OIDC RT, so the new one must not be
  dropped. Guarded by `revoked_at IS NULL` (no resurrection of revoked rows);
  `:error` when the device has no active row any more.
  """
  @spec store_rotated_oidc_rt(String.t(), String.t(), String.t()) :: :ok | :error
  def store_rotated_oidc_rt(user_id, device_id, enc_oidc_rt)
      when is_binary(user_id) and is_binary(device_id) and is_binary(enc_oidc_rt) do
    case query(
           """
           UPDATE matrix_sessions
              SET oidc_refresh_token = $3
            WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL AND auth_api = 'legacy'
           """,
           [user_id, device_id, enc_oidc_rt]
         ) do
      {:ok, %{num_rows: n}} when n >= 1 -> :ok
      {:ok, _} -> :error
    end
  end

  @doc """
  Hard-revokes a session by deleting rows (logout).

  Looks up the presented access token's `(user_id, device_id)` and deletes ALL
  rows for that pair — the presented row plus every soft-revoked (pending or
  consumed) rotated sibling, so logout leaves no redeemable refresh token behind.
  If the access token is unknown, this is a no-op `:ok`.
  """
  @spec revoke(String.t()) :: :ok
  def revoke(access_token) when is_binary(access_token) do
    case query(
           "SELECT user_id, device_id FROM matrix_sessions WHERE access_token_hash = $1",
           [hash_token(access_token)]
         ) do
      {:ok, %{rows: [[user_id, device_id]]}} ->
        {:ok, _} =
          query(
            "DELETE FROM matrix_sessions WHERE user_id = $1 AND device_id = $2",
            [user_id, device_id]
          )

        :ok

      _ ->
        # Unknown access token — nothing to delete.
        :ok
    end
  end

  @doc """
  Deletes ALL opaque sessions for a user across every device (admin deactivation /
  full logout). Best-effort: never raises — logs a warning and returns `:ok` on a
  query failure so it cannot break the wider session-invalidation path (mirrors the
  Go "logs as warning, does not block" contract). MINOR-2.
  """
  @spec delete_for_user(String.t()) :: :ok
  def delete_for_user(user_id) when is_binary(user_id) do
    case safe_query("DELETE FROM matrix_sessions WHERE user_id = $1", [user_id]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("matrix_sessions delete_for_user failed",
          user_id: user_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Deletes opaque sessions for a single `(user_id, device_id)` WITHOUT the devices-row lock.
  Best-effort like `delete_for_user/1` (MINOR-2). The Matrix `POST /logout` does NOT use it any more
  (bugfix legacy-logout-per-device: `Nebu.Matrix.legacy_logout_device/1`, locked teardown).
  """
  @spec delete_for_user_device(String.t(), String.t()) :: :ok
  def delete_for_user_device(user_id, device_id)
      when is_binary(user_id) and is_binary(device_id) do
    case safe_query(
           "DELETE FROM matrix_sessions WHERE user_id = $1 AND device_id = $2",
           [user_id, device_id]
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("matrix_sessions delete_for_user_device failed",
          user_id: user_id,
          device_id: device_id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Deletes a SINGLE session row by its exact access token (hashed internally), but
  ONLY while it is still the active (non-revoked) row — guarded by
  `revoked_at IS NULL`. See `delete_by_access_token_hash/1`.

  security-review fix (server-paced-session-refresh / background-session-refresh-worker,
  HIGH finding #1): `Nebu.Matrix.Session.RefreshWorker.redeem/1`'s fail-closed
  path on a CONFIRMED upstream rejection must delete ONLY the exact row it
  re-selected and acted on — never the wider `(user_id, device_id)` pair via
  `delete_for_user_device/2`. In the supported clustered deployment, every
  node runs its own instance of the worker against the same shared table; two
  nodes can race to redeem the same (rotating) upstream refresh token. The
  winner rotates to a healthy NEW row and soft-revokes the old one
  (`rotate_tokens/1`, guarded UPDATE on the access token hash with
  `revoked_at IS NULL`); the loser's redemption then fails (the RT was already
  consumed) and must NOT delete the winner's brand-new row. Scoping this
  delete by the loser's OWN (now stale) access token hash AND `revoked_at IS
  NULL` gives it the same true per-row atomicity `rotate_tokens/1` already
  has: if another node already superseded this row (soft-revoked or deleted
  it), this delete matches 0 rows and cannot touch a sibling/replacement row.

  Deliberately NOT a replacement for `delete_for_user_device/2` — that
  function's wide `(user_id, device_id)` scope is correct and intentional for
  explicit, single-actor, user-initiated device removal (`delete_one_device`
  in `protected.ex`) and the client-driven `/refresh` fail-closed path
  (`do_refresh_with/2`), where there is no sibling winner racing the delete.
  This function exists ONLY for callers (like the background worker) that
  fan out across multiple nodes/rows and must not risk deleting a row they
  did not themselves select.

  Best-effort like the other delete helpers: never raises.
  """
  @spec delete_by_access_token(String.t()) :: :ok
  def delete_by_access_token(access_token) when is_binary(access_token),
    do: delete_by_access_token_hash(hash_token(access_token))

  @doc false
  # INTERNAL - pass-the-hash warning: only for hash values read from the DB (RefreshWorker,
  # HttpPublic.rotate_attempt). NEVER pass a client-supplied value here: a leaked hash
  # must not act as a credential. Public API takes plaintext tokens only.
  @spec delete_by_access_token_hash(String.t()) :: :ok
  def delete_by_access_token_hash(access_token_hash) when is_binary(access_token_hash) do
    case safe_query(
           "DELETE FROM matrix_sessions WHERE access_token_hash = $1 AND revoked_at IS NULL",
           [access_token_hash]
         ) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("matrix_sessions delete_by_access_token failed",
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Deletes sessions whose `expires_at` is more than 7 days in the past. Returns the
  number of rows deleted. Not wired to a periodic sweeper yet (no supervised
  session sweeper exists) — call it from one when added.

  NOTE: pending soft-revoked rows (old refresh tokens) now live until their own
  `expires_at` (no 60s window), so `matrix_sessions` grows by one row per client
  refresh until logout / device delete / this cleanup. A periodic sweeper is a
  named follow-up (see the story's Dev Notes); it is deliberately not wired here.
  """
  @spec cleanup_expired() :: non_neg_integer()
  def cleanup_expired do
    {:ok, %{num_rows: n}} =
      query(
        "DELETE FROM matrix_sessions WHERE COALESCE(session_expires_at, expires_at) < NOW() - INTERVAL '7 days'",
        []
      )

    n
  end

  @doc """
  Refreshes `auth_time` (unix seconds) for ALL of a user's active opaque sessions
  (S3). Called after the user completes a fresh `m.login.sso` UIA stage so the
  subsequent re-submit on the SAME opaque token is within the fresh-auth window.
  Best-effort: never raises.
  """
  @spec refresh_auth_time(String.t(), integer()) :: :ok
  def refresh_auth_time(user_id, auth_time)
      when is_binary(user_id) and is_integer(auth_time) do
    _ =
      safe_query(
        # story oauth-legacy-coexistence (C9): legacy rows ONLY — a legacy UIA completion must not mark the
        # user's OAuth sessions as freshly authenticated (their auth_time is the IdP login time).
        "UPDATE matrix_sessions SET auth_time = $2 WHERE user_id = $1 AND revoked_at IS NULL AND auth_api = 'legacy'",
        [user_id, auth_time]
      )

    :ok
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp select_sql(where) do
    """
    SELECT access_token_hash, refresh_token_hash, oidc_refresh_token, user_id, device_id,
           expires_at, revoked_at, grace_until, auth_api
      FROM matrix_sessions
     WHERE #{where}
    """
  end

  defp row_to_session([at_h, rt_h, enc_oidc_rt, user_id, device_id, expires_at, revoked_at, grace_until, auth_api]) do
    %{
      access_token_hash: at_h,
      refresh_token_hash: rt_h,
      oidc_refresh_token: enc_oidc_rt,
      user_id: user_id,
      device_id: device_id,
      expires_at: expires_at,
      revoked_at: revoked_at,
      grace_until: grace_until,
      auth_api: auth_api
    }
  end

  # NOTE (enhanced-logging/matrix-payload-debug-logging, CI-gate cycle-2 bug 2):
  # this module binds token hashes (and encrypted OIDC refresh tokens) as SQL
  # parameters in every query. Ecto's default query logger would emit those
  # bound params verbatim at :debug level. Rather than disabling logging on a
  # per-call-site basis here, the fix is global: `config :nebu, Nebu.Repo,
  # log: false` (server/config/config.exs) disables Ecto's own Logger call for
  # ALL queries everywhere, and `Nebu.Repo.QueryTelemetry`
  # (server/lib/nebu/repo/query_telemetry.ex) attaches to the
  # `[:nebu, :repo, :query]` telemetry event to log a SANITIZED summary
  # (source + duration_ms only, never bound parameters) at :debug. See that
  # module for details. This keeps every query in the codebase — not just
  # this module's — safe at :debug level, now and for any future query.
  defp query(sql, params), do: Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)

  # Read-path query that never raises: a failed lookup (DB down / not started, or a
  # query error) is reported as `{:error, _}` so the opaque-token auth path treats
  # it as "cannot authenticate this token" (→ 401) instead of crashing the request.
  # Used only by the lookups; writes (create/rotate/revoke) still surface failures.
  defp safe_query(sql, params) do
    if Process.whereis(Nebu.Repo) do
      query(sql, params)
    else
      {:error, :repo_not_started}
    end
  rescue
    e -> {:error, e}
  end
end
