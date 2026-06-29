defmodule Nebu.Matrix.Session.DeviceBinding do
  @moduledoc """
  Server-side token->device binding for raw OIDC-JWT access tokens
  (story s2-device-lifecycle-at-login, AC3 / SECURITY G1).

  An opaque Nebu session already records its device in `matrix_sessions.device_id`,
  so `OidcPlug` resolves the device for opaque tokens from there. A raw OIDC JWT
  carries no Nebu device_id (it is issued by the IdP), so login persists a
  `token -> device_id` association HERE, and `OidcPlug.call_jwt/2` looks it up on
  every authenticated request. This makes the device a request acts as
  SERVER-AUTHORITATIVE: it is read from this binding, never taken from
  attacker-controllable request input.

  Plain module, inline parameterised SQL via `Nebu.Repo` (ADR-018 — no Ecto schema,
  no Repository/Service layer). PostgreSQL-backed so it is cluster-correct (ADR-020):
  login and a later request may land on different nodes.

  ## The token is never stored in the clear

  The row is keyed by the SHA-256 hex digest of the access token, not the token
  itself — a DB dump never exposes usable bearer tokens, and the binding still
  resolves deterministically from the presented token.
  """

  @doc """
  Records (or refreshes) the device a raw-JWT access token is bound to.

  Idempotent on the token hash: a re-login with the same JWT keeps the binding. A
  different JWT for the same (user, device) gets its own row — the device_id is
  whatever login bound, never client-request-controllable.
  """
  @spec put(String.t(), String.t(), String.t(), integer() | nil) :: :ok
  def put(access_token, user_id, device_id, exp \\ nil)
      when is_binary(access_token) and is_binary(user_id) and is_binary(device_id) do
    # Best-effort, mirroring `get_device/1`: an unavailable/missing
    # `jwt_device_bindings` table must NOT crash the login (or the lazy-bind during
    # /keys/upload). The worst case is that a later raw-JWT request resolves "no
    # bound device" and is handled exactly as an unbound token — never a 500.
    #
    # S3 F-1: `exp` (the verified JWT's exp, unix seconds) is persisted so the
    # device-delete kill-switch can denylist the bound token until its own expiry.
    # nil exp keeps the row resolvable but yields no kill-switch entry for that token.
    _ =
      safe_query(
        """
        INSERT INTO jwt_device_bindings (token_hash, user_id, device_id, exp, created_at)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (token_hash) DO UPDATE
          SET user_id = EXCLUDED.user_id, device_id = EXCLUDED.device_id,
              exp = COALESCE(EXCLUDED.exp, jwt_device_bindings.exp)
        """,
        [hash(access_token), user_id, device_id, exp, System.system_time(:millisecond)]
      )

    # Prime the read cache so a request that arrives within the TTL of a prior cached
    # MISS (e.g. an OTK-only top-up right after the first device_keys upload that
    # lazily bound this token) resolves the new device immediately, not nil.
    cache_put(hash(access_token), device_id)
    :ok
  end

  @doc """
  Returns the device_id bound to a raw-JWT access token, or `nil` when none is
  recorded / the DB is unavailable. Read-path: never raises so the auth pipeline
  degrades to "no bound device" rather than crashing the request.

  This runs on EVERY raw-JWT authenticated request (it is how `OidcPlug` resolves
  the device), so it is backed by a per-node TTL cache (mirrors OidcPlug's
  provisioning cache): a token's binding is stable for its lifetime, so the DB is
  read at most once per token per TTL window instead of on every /sync long-poll.
  `put/3` primes the cache so a freshly-bound token resolves immediately without a
  read. Best-effort: a missing table just means every call reads through to the DB.
  """
  @spec get_device(String.t()) :: String.t() | nil
  def get_device(access_token) when is_binary(access_token) do
    h = hash(access_token)

    case cache_get(h) do
      {:hit, device_id} ->
        device_id

      :miss ->
        device_id =
          case safe_query(
                 "SELECT device_id FROM jwt_device_bindings WHERE token_hash = $1",
                 [h]
               ) do
            {:ok, %{rows: [[device_id]]}} -> device_id
            _ -> nil
          end

        cache_put(h, device_id)
        device_id
    end
  end

  @doc """
  Returns `[{token_hash, exp}]` for every raw-JWT binding of a `(user_id, device_id)`
  pair (S3 F-1 kill-switch enumeration; served by `idx_jwt_device_bindings_user_device`).
  `exp` may be `nil` for a row written before the exp column existed. Read-path: never
  raises (returns `[]` on an unavailable DB).
  """
  @spec list_for_user_device(String.t(), String.t()) :: [{String.t(), integer() | nil}]
  def list_for_user_device(user_id, device_id)
      when is_binary(user_id) and is_binary(device_id) do
    case safe_query(
           "SELECT token_hash, exp FROM jwt_device_bindings WHERE user_id = $1 AND device_id = $2",
           [user_id, device_id]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [h, exp] -> {h, exp} end)
      _ -> []
    end
  end

  @doc """
  Deletes all bindings for a `(user_id, device_id)` (S3, after the kill-switch has
  denylisted each token). Best-effort: never raises. Also invalidates the per-node
  cache entry for each deleted token-hash so a stale "bound" cache cannot resolve a
  device that no longer exists.
  """
  @spec delete_for_user_device(String.t(), String.t()) :: :ok
  def delete_for_user_device(user_id, device_id)
      when is_binary(user_id) and is_binary(device_id) do
    for {h, _exp} <- list_for_user_device(user_id, device_id), do: cache_delete(h)

    _ =
      safe_query(
        "DELETE FROM jwt_device_bindings WHERE user_id = $1 AND device_id = $2",
        [user_id, device_id]
      )

    :ok
  end

  @doc """
  The SHA-256 lowercase-hex digest of an access token — the key this module stores
  bindings under, the value `list_for_user_device/2` returns, and the same digest the
  F-1 kill-switch / `OidcPlug` `revoked?` lookup resolve a live token by. Exposed so
  the device-delete handler can identify (and spare) the CALLER's own bound token by
  its hash when the caller deletes its own device.
  """
  @spec hash(String.t()) :: String.t()
  def hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  # ── internals ──────────────────────────────────────────────────────────────

  # ── per-node TTL cache (token_hash -> {device_id | nil, cached_at_monotonic_ms}) ──
  # A bound token's device never changes, so a short TTL is safe and lifts the
  # per-request DB read off the /sync hot path. A `nil` (no binding) is cached too so
  # a forged/never-logged-in JWT does not hit the DB on every request either.
  @cache_table :nebu_jwt_device_binding_cache
  @cache_ttl_ms 60_000

  defp cache_get(hash) do
    ensure_table()

    case :ets.lookup(@cache_table, hash) do
      [{^hash, device_id, cached_at}] ->
        if now_ms() - cached_at < @cache_ttl_ms, do: {:hit, device_id}, else: :miss

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(hash, device_id) do
    ensure_table()
    :ets.insert(@cache_table, {hash, device_id, now_ms()})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp cache_delete(hash) do
    ensure_table()
    :ets.delete(@cache_table, hash)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp ensure_table do
    case :ets.whereis(@cache_table) do
      :undefined ->
        try do
          :ets.new(@cache_table, [:set, :public, :named_table, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  defp query(sql, params), do: Ecto.Adapters.SQL.query(Nebu.Repo, sql, params)

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
