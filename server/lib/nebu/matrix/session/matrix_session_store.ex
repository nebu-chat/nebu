defmodule Nebu.Matrix.Session.MatrixSessionStore do
  @moduledoc """
  Opaque Matrix access/refresh-token session store (oidc-session-refresh).

  Plain module, inline parameterised SQL via `Nebu.Repo` (ADR-018 — no Ecto
  schema, no Repository/Service layer). Backs the `matrix_sessions` table that
  already exists in the canonical schema
  (`server/priv/migrations/000001_init.up.sql`); this story adds NO migration.

  Ports the Go reference `gateway/internal/db/matrix_session_store.go`.

  ## What it stores

  When a Matrix client logs in with `refresh_token: true` and an OIDC refresh
  token was captured during SSO, login mints an opaque access token + refresh
  token (32 random bytes → 64 lowercase hex chars, no `.`, so distinguishable
  from a JWT) and persists them here together with the AES-256-GCM-encrypted OIDC
  refresh token and a Nebu-controlled `expires_at = min(oidc_exp, now + 8h)`.

  ## Token rotation + grace period (Matrix CS API v1.18 §refreshing-access-tokens)

  `POST /refresh` calls `rotate_tokens/1`, which in a SINGLE transaction:

    * soft-revokes the old row (`revoked_at = NOW()`,
      `grace_until = NOW() + INTERVAL '60 seconds'`), and
    * inserts the new AT/RT row, carrying over the encrypted OIDC RT.

  The old refresh token therefore stays resolvable via `get_by_refresh_token/1`
  during the 60-second grace window (spec MUST: old RT valid until the new tokens
  are used) — `mark_access_token_used/1` closes that window early the first time
  the new access token is used.

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
          (access_token, refresh_token, oidc_refresh_token, user_id, device_id, expires_at, auth_time, created_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())
        """,
        [at, rt, enc_oidc_rt, user_id, device_id, expires_at, auth_time]
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
           "SELECT user_id, device_id, auth_time FROM matrix_sessions WHERE access_token = $1",
           [access_token]
         ) do
      {:ok, %{rows: [[user_id, device_id, auth_time]]}} ->
        {:ok, %{user_id: user_id, device_id: device_id, auth_time: auth_time}}

      _ ->
        :error
    end
  end

  @doc """
  Looks up a session by opaque access token. Returns `{:ok, session}` or `:error`.

  The session map exposes `:access_token`, `:refresh_token`, `:oidc_refresh_token`
  (encrypted, may be `nil`), `:user_id`, `:device_id`, `:expires_at`,
  `:revoked_at`, `:grace_until`. The expiry decision is made by the caller
  (`OidcPlug`) so the AC5 `soft_logout` path can distinguish expired from absent.
  """
  @spec get_by_access_token(String.t()) :: {:ok, map()} | :error
  def get_by_access_token(access_token) when is_binary(access_token) do
    case safe_query(select_sql("access_token = $1"), [access_token]) do
      {:ok, %{rows: [row]}} -> {:ok, row_to_session(row)}
      _ -> :error
    end
  end

  @doc """
  Looks up a session by opaque refresh token, honouring the grace window.

  Returns the row when `revoked_at IS NULL` (active) OR `grace_until > NOW()`
  (a soft-revoked old RT still inside its grace window, AC4). A revoked row whose
  grace window has elapsed, or an unknown token, yields `:error` (AC6).
  """
  @spec get_by_refresh_token(String.t()) :: {:ok, map()} | :error
  def get_by_refresh_token(refresh_token) when is_binary(refresh_token) do
    case safe_query(
           select_sql("refresh_token = $1 AND (revoked_at IS NULL OR grace_until > NOW())"),
           [refresh_token]
         ) do
      {:ok, %{rows: [row]}} -> {:ok, row_to_session(row)}
      _ -> :error
    end
  end

  @doc """
  Atomically rotates a session's AT+RT pair (single transaction).

  Soft-revokes the old row (`revoked_at = NOW()`, `grace_until = NOW() + 60s`) and
  inserts the new row, carrying over the encrypted OIDC RT unless `:new_oidc_refresh_token`
  supplies a fresh one. Returns `:error` if the old access token is unknown /
  already revoked (the caller maps that to 401).

  `params`: `:old_access_token`, `:new_access_token`, `:new_refresh_token`,
  `:new_expires_at` (DateTime), optional `:new_oidc_refresh_token` (already
  AES-256-GCM encrypted — story `matrix-refresh-revalidates-with-idp` AC4:
  `Nebu.Matrix.HttpPublic.do_refresh_with/2` is the first caller to actually
  populate this when the IdP round-trip it now performs returns a
  provider-rotated OIDC refresh token; previously this param existed but was
  never supplied by any caller, so the encrypted OIDC RT only ever carried
  over unchanged).
  """
  @spec rotate_tokens(map()) :: :ok | :error
  def rotate_tokens(%{
        old_access_token: old_at,
        new_access_token: new_at,
        new_refresh_token: new_rt,
        new_expires_at: new_expires_at
      } = params) do
    new_oidc_rt = Map.get(params, :new_oidc_refresh_token)

    txn =
      Nebu.Repo.transaction(fn ->
        # 1. Soft-revoke the old row. grace_until gives the old RT a 60s window.
        case query(
               """
               UPDATE matrix_sessions
                  SET revoked_at = NOW(), grace_until = NOW() + INTERVAL '60 seconds'
                WHERE access_token = $1 AND revoked_at IS NULL
               """,
               [old_at]
             ) do
          {:ok, %{num_rows: 0}} ->
            Nebu.Repo.rollback(:not_found)

          {:ok, _} ->
            # 2. Read the old row to copy user_id/device_id, (default) the OIDC RT,
            #    and — S3 — the auth_time VERBATIM. A refresh is NOT a fresh
            #    authentication, so it must carry over the original auth_time
            #    unchanged; resetting it here would let a refresh defeat the UIA
            #    freshness gate (story Dev Notes).
            {:ok, %{rows: [[user_id, device_id, old_enc_oidc_rt, old_auth_time]]}} =
              query(
                "SELECT user_id, device_id, oidc_refresh_token, auth_time FROM matrix_sessions WHERE access_token = $1",
                [old_at]
              )

            enc_oidc_rt = new_oidc_rt || old_enc_oidc_rt

            # 3. Insert the new row, carrying auth_time over unchanged.
            {:ok, _} =
              query(
                """
                INSERT INTO matrix_sessions
                  (access_token, refresh_token, oidc_refresh_token, user_id, device_id, expires_at, auth_time, created_at)
                VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())
                """,
                [new_at, new_rt, enc_oidc_rt, user_id, device_id, new_expires_at, old_auth_time]
              )

            :ok
        end
      end)

    case txn do
      {:ok, :ok} -> :ok
      {:error, :not_found} -> :error
    end
  end

  @doc """
  Closes the grace window of any soft-revoked sibling row for the same user+device
  the first time `access_token` is used (AC4 — old RT invalid once new tokens are
  used). Idempotent: a no-op when no open grace sibling exists, and harmless on an
  unknown token.
  """
  @spec mark_access_token_used(String.t()) :: :ok
  def mark_access_token_used(access_token) when is_binary(access_token) do
    case query(
           "SELECT user_id, device_id FROM matrix_sessions WHERE access_token = $1",
           [access_token]
         ) do
      {:ok, %{rows: [[user_id, device_id]]}} ->
        {:ok, _} =
          query(
            """
            UPDATE matrix_sessions
               SET grace_until = NOW()
             WHERE user_id = $1 AND device_id = $2
               AND revoked_at IS NOT NULL
               AND grace_until > NOW()
               AND access_token != $3
            """,
            [user_id, device_id, access_token]
          )

        :ok

      _ ->
        # Unknown AT — nothing to expire.
        :ok
    end
  end

  @doc """
  Indicates whether `access_token` has an OPEN grace window on a soft-revoked
  sibling (same user+device), folded into one query (Go `LookupOpaqueToken`
  has_grace EXISTS subquery). Lets `OidcPlug` skip `mark_access_token_used/1` —
  and its write — on the common request path where no rotation happened.
  Only meaningful when the AT itself is not revoked.
  """
  @spec has_open_grace_window?(String.t()) :: boolean()
  def has_open_grace_window?(access_token) when is_binary(access_token) do
    case safe_query(
           """
           SELECT EXISTS(
             SELECT 1 FROM matrix_sessions s2
              WHERE s2.user_id = m.user_id
                AND s2.device_id = m.device_id
                AND s2.access_token != m.access_token
                AND s2.revoked_at IS NOT NULL
                AND s2.grace_until > NOW()
           )
           FROM matrix_sessions m
           WHERE m.access_token = $1 AND m.revoked_at IS NULL
           """,
           [access_token]
         ) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  @doc """
  Hard-revokes a session by deleting rows (logout).

  Looks up the presented access token's `(user_id, device_id)` and deletes ALL
  rows for that pair — the presented row plus any soft-revoked rotated siblings
  still lingering inside their grace window (MINOR-1: stop logout from leaving
  siblings behind; the periodic `cleanup_expired/0` sweeper is still deferred).
  If the access token is unknown, this is a no-op `:ok`.
  """
  @spec revoke(String.t()) :: :ok
  def revoke(access_token) when is_binary(access_token) do
    case query(
           "SELECT user_id, device_id FROM matrix_sessions WHERE access_token = $1",
           [access_token]
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
  Deletes opaque sessions for a single `(user_id, device_id)` (per-device
  `POST /logout`). Best-effort like `delete_for_user/1` (MINOR-2).
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
  Deletes sessions whose `expires_at` is more than 7 days in the past. Returns the
  number of rows deleted. Not wired to a periodic sweeper yet (no supervised
  session sweeper exists) — call it from one when added.
  """
  @spec cleanup_expired() :: non_neg_integer()
  def cleanup_expired do
    {:ok, %{num_rows: n}} =
      query("DELETE FROM matrix_sessions WHERE expires_at < NOW() - INTERVAL '7 days'", [])

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
        "UPDATE matrix_sessions SET auth_time = $2 WHERE user_id = $1 AND revoked_at IS NULL",
        [user_id, auth_time]
      )

    :ok
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp select_sql(where) do
    """
    SELECT access_token, refresh_token, oidc_refresh_token, user_id, device_id,
           expires_at, revoked_at, grace_until
      FROM matrix_sessions
     WHERE #{where}
    """
  end

  defp row_to_session([at, rt, enc_oidc_rt, user_id, device_id, expires_at, revoked_at, grace_until]) do
    %{
      access_token: at,
      refresh_token: rt,
      oidc_refresh_token: enc_oidc_rt,
      user_id: user_id,
      device_id: device_id,
      expires_at: expires_at,
      revoked_at: revoked_at,
      grace_until: grace_until
    }
  end

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
