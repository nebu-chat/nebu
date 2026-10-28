defmodule Nebu.Web.TokenDenylist do
  @moduledoc """
  ETS-as-cache + PostgreSQL-as-persistent-store denylist of revoked access tokens
  (matrix-api-migration, F-1; persistence added in fix-jwt-denylist-persistence).

  ## Why this exists

  With the Go gateway removed from the request path, the Elixir stack is the
  single auth point. The Go gateway revoked a token on `POST /logout` by writing
  it to a persistent `invalidated_tokens` denylist (`gateway/internal/db/tokenstore.go`)
  and consulting that denylist on EVERY authenticated request
  (`gateway/internal/middleware/auth.go` "Step 2: Denylist check"). The migrated
  Elixir path returns the verified OIDC token verbatim as the `access_token`, so
  WITHOUT a denylist a logged-out token would keep re-validating (signature + exp +
  iss + aud) and stay accepted until its OIDC `exp` — logout would be a no-op.

  `OidcPlug.call/2` consults this denylist after a token verifies; `POST /logout`
  adds the presented token here. A denylisted token is rejected with
  `401 M_UNKNOWN_TOKEN`.

  ## Key derivation (Go parity)

  An entry is keyed by the JWT `jti` claim when present (a stable, compact token
  identifier), otherwise by the SHA-256 hash of the raw compact token (matching
  the Go `pgTokenHash`/`tokenHash` — the raw token is never stored). Both forms
  live in the same table; a token is denylisted if EITHER its `jti` or its hash
  is present, so a logout that recorded one form is honoured regardless of which
  form a later request resolves to.

  ## Persistence / restart strategy (ADR-018 inline SQL)

  ETS is a write-through fast-path cache; PostgreSQL (`invalidated_tokens` table)
  is the persistent truth source:

    * **`revoke/3`**: writes to ETS first, then persists to DB via a single
      parameterised `INSERT … ON CONFLICT (token_hash) DO NOTHING`. The DB write
      is best-effort (logged as `:warning` on failure, never crashes).

    * **`revoked?/2`**: checks ETS first (fast path, no DB round-trip). On an ETS
      miss it falls back to a `SELECT` on `invalidated_tokens` (AC2). DB results
      are NOT back-populated into ETS — ETS is a write-through cache only (avoids
      stale-cache issues in rolling-restart / cluster scenarios).

    * **Restart survival (AC4)**: after a node restart ETS is empty, but DB rows
      persist. The first request for a revoked token finds nothing in ETS and is
      correctly rejected via the DB fallback.

  ## DB key encoding (different from ETS key encoding)

  ETS uses tagged Erlang tuples: `{:jti, jti}` / `{:hash, hex}`.
  The DB `token_hash TEXT` column stores flat strings (ADR-018, no Erlang types):
    - jti present → `"jti:<jti_value>"` (namespace prefix avoids collision)
    - jti absent  → `"<sha256_hex>"` (64 lowercase hex chars — same hash, no tuple wrapper)

  On write, the primary key (jti-based when available, hash-based otherwise) is stored.
  On read, `revoked?/2` checks both the jti key and hash key in DB so that a lookup
  on a different node (which may have recorded either form) still returns true.

  Each ETS entry carries the token's `exp` (unix seconds); a lookup treats an entry
  whose `exp` is in the past as absent (and lazily deletes it), so the table does
  not grow without bound and a re-issued token sharing a hash is never wrongly
  blocked past its lifetime. The DB uses the same `expires_at` BIGINT (unix seconds)
  with `expires_at > $now` in the SELECT predicate (lazy expiry — no proactive delete).
  """

  require Logger

  @table :nebu_http_token_denylist

  @doc """
  Eagerly creates the backing ETS table (called from the Application supervisor
  at boot, R-2). Idempotent — safe if the table already exists. Returns `:ok`.
  """
  @spec init_table() :: :ok
  def init_table, do: ensure_table()

  @doc """
  Records a token as revoked until `exp` (unix seconds).

  `jti` is the JWT `jti` claim (string) or `nil`. `token` is the raw compact
  JWS. When `jti` is present it is used as the key; otherwise the SHA-256 hash of
  the raw token is used (Go parity, raw token never stored). Idempotent.
  """
  @spec revoke(String.t() | nil, String.t(), integer()) :: :ok
  def revoke(jti, token, exp) when is_integer(exp) do
    ensure_table()
    db_k = db_key(jti, token)
    k = key(jti, token)

    if k == nil do
      Logger.warning("TokenDenylist.revoke called with no usable key — token cannot be revoked")
      :ok
    else
      try do
        :ets.insert(@table, {k, exp})
      rescue
        ArgumentError -> :ok
      end

      # AC1, AC7: persist to DB (best-effort — never crash on DB failure)
      db_revoke(db_k, exp)
      :ok
    end
  end

  @doc """
  Like `revoke/3`, but REPORTS a failed durable (database) write: `:ok` once the entry is in the ETS set
  AND the database, `{:error, reason}` when the database write failed (the ETS entry is kept). Used where a
  silent failure would leave a credential alive while the caller reports success (story
  oauth-token-revocation-logout, review cycle 1: `POST /logout/all`).
  """
  @spec revoke_checked(String.t() | nil, String.t(), integer()) :: :ok | {:error, term()}
  def revoke_checked(jti, token, exp) when is_integer(exp) do
    ensure_table()
    db_k = db_key(jti, token)
    k = key(jti, token)

    if k == nil do
      Logger.warning("TokenDenylist.revoke_checked called with no usable key — token cannot be revoked")
      {:error, :no_key}
    else
      try do
        :ets.insert(@table, {k, exp})
      rescue
        ArgumentError -> :ok
      end

      db_revoke_checked(db_k, exp)
    end
  end

  @doc """
  Revokes a token by its SHA-256 hex digest (S3 F-1 kill-switch).

  When a device is deleted, the only handle we hold for a JWT bound to it is the
  `jwt_device_bindings.token_hash` — the raw token was never stored. That hash is
  `SHA-256(token)` in lowercase hex, the SAME digest `revoked?/2` computes from the
  LIVE token via `hash_key/1` (ETS `{:hash, hex}`) / `hash_db_key/1` (DB plain hex).
  So inserting a denylist entry keyed by that hash means the next request carrying
  the bound JWT resolves `revoked?(jti, token) == true` and OidcPlug rejects it with
  401 M_UNKNOWN_TOKEN. `exp` (unix seconds) bounds the entry's lifetime; a `nil`/non-
  integer exp is NOT revoked durably: `{:error, :no_exp}` (story oauth-legacy-coexistence C13).

  Returns `:ok` once the entry is in the node-local ETS set AND the database (cluster wide), and
  `{:error, reason}` when the database write failed (the ETS entry is kept: the token is dead on THIS
  node). Callers that delete the token's binding row must do so ONLY on `:ok` (C13): otherwise the
  token would authenticate again, device-less, on every other node.
  """
  @spec revoke_by_hash(String.t() | nil, integer() | nil) :: :ok | {:error, term()}
  def revoke_by_hash(token_hash, exp) when is_binary(token_hash) and token_hash != "" and is_integer(exp) do
    ensure_table()

    try do
      :ets.insert(@table, {{:hash, token_hash}, exp})
    rescue
      ArgumentError -> :ok
    end

    # DB key for a hash-based entry is the plain hex string (same encoding hash_db_key
    # produces), so a cross-node lookup via db_revoked_any? finds it.
    db_revoke_checked(token_hash, exp)
  end

  # No expiry => nothing durable to anchor the entry to: the caller must treat the revocation as
  # NOT confirmed (story oauth-legacy-coexistence, C13: it keeps the binding and fails closed).
  def revoke_by_hash(token_hash, nil) when is_binary(token_hash) and token_hash != "", do: {:error, :no_exp}

  def revoke_by_hash(_token_hash, _exp), do: :ok

  @doc """
  Returns true if the token (by `jti` or by hash) is currently denylisted.

  An entry whose `exp` is in the past is treated as absent and lazily deleted.
  """
  @spec revoked?(String.t() | nil, String.t()) :: boolean()
  def revoked?(jti, token) do
    ensure_table()
    # AC3: ETS fast path — scope rescue to ETS ops only so DB fallback always runs
    ets_result =
      try do
        revoked_key?(jti_key(jti)) or revoked_key?(hash_key(token))
      rescue
        ArgumentError -> false
      end

    if ets_result do
      true
    else
      # AC2, AC4: ETS miss — fall back to DB for both key forms
      # (a revocation written by a different node may only be in DB)
      db_revoked_any?(jti, token)
    end
  end

  defp revoked_key?(nil), do: false

  defp revoked_key?(k) do
    case :ets.lookup(@table, k) do
      [{^k, exp}] ->
        if exp > System.system_time(:second) do
          true
        else
          :ets.delete(@table, k)
          false
        end

      _ ->
        false
    end
  end

  # ── ETS key helpers (tagged tuples — DO NOT CHANGE; existing tests depend on this) ──

  # Prefer jti when present (stable, compact); fall back to a token hash.
  defp key(jti, token), do: jti_key(jti) || hash_key(token)

  defp jti_key(jti) when is_binary(jti) and jti != "", do: {:jti, jti}
  defp jti_key(_), do: nil

  defp hash_key(token) when is_binary(token) and token != "" do
    {:hash, :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)}
  end

  defp hash_key(_), do: nil

  # ── DB key helpers (flat strings — different namespace from ETS tuples) ──────
  # AC5: jti present → "jti:<jti_value>", jti absent → plain SHA-256 hex string.
  # These are stored in the single `token_hash TEXT` column of `invalidated_tokens`.

  defp jti_db_key(jti) when is_binary(jti) and jti != "", do: "jti:" <> jti
  defp jti_db_key(_), do: nil

  defp hash_db_key(token) when is_binary(token) and token != "" do
    :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
  end

  defp hash_db_key(_), do: nil

  # Returns the primary DB key for a revoke call (jti preferred, hash fallback).
  defp db_key(jti, token), do: jti_db_key(jti) || hash_db_key(token)

  # ── DB write (best-effort, AC1, AC7) ─────────────────────────────────────────

  defp db_revoke(db_key, exp) when is_binary(db_key) do
    sql =
      "INSERT INTO invalidated_tokens (token_hash, expires_at) VALUES ($1, $2) ON CONFLICT (token_hash) DO NOTHING"

    case safe_query(sql, [db_key, exp]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("TokenDenylist.db_revoke failed", key: db_key, reason: inspect(reason))
        :ok
    end
  end

  defp db_revoke(nil, _exp), do: :ok

  defp db_revoke_checked(nil, _exp), do: :ok

  defp db_revoke_checked(db_key, exp) when is_binary(db_key) do
    sql =
      "INSERT INTO invalidated_tokens (token_hash, expires_at) VALUES ($1, $2) ON CONFLICT (token_hash) DO NOTHING"

    case safe_query(sql, [db_key, exp]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("TokenDenylist.db_revoke failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  # ── DB read fallback (best-effort, AC2, AC4, AC6, AC8) ───────────────────────

  # Check both jti key and hash key in DB — a different node may have written only one form.
  defp db_revoked_any?(jti, token) do
    db_revoked?(jti_db_key(jti)) or db_revoked?(hash_db_key(token))
  end

  defp db_revoked?(nil), do: false

  defp db_revoked?(db_key) when is_binary(db_key) do
    now = System.system_time(:second)
    # AC6: expires_at > now (lazy expiry — expired rows treated as absent, not deleted)
    sql =
      "SELECT 1 FROM invalidated_tokens WHERE token_hash = $1 AND expires_at > $2 LIMIT 1"

    case safe_query(sql, [db_key, now]) do
      {:ok, %{num_rows: n}} when n > 0 -> true
      # AC8: any error (including Repo absent) returns false — never crash
      _ -> false
    end
  end

  # ── Shared safe_query helper (mirrors MatrixSessionStore.safe_query/2, ADR-018) ─

  defp safe_query(sql, params) do
    if Process.whereis(Nebu.Repo) do
      Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)
    else
      {:error, :repo_not_started}
    end
  rescue
    e -> {:error, e}
  end

  # Lazily create the public, named set on first use. Two processes can race to
  # create it — the loser gets ArgumentError, which is fine (it already exists).
  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
          :ok
        rescue
          ArgumentError -> :ok
        end

      _ref ->
        :ok
    end
  end
end
