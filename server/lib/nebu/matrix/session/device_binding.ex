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

  require Logger

  @doc """
  Records (or refreshes) the device a raw-JWT access token is bound to.

  Idempotent on the token hash: a re-login with the same JWT keeps the binding. A
  different JWT for the same (user, device) gets its own row — the device_id is
  whatever login bound, never client-request-controllable.
  """
  @spec put(String.t(), String.t(), String.t(), integer() | nil) :: :ok | {:error, :oauth_device}
  def put(access_token, user_id, device_id, exp \\ nil)
      when is_binary(access_token) and is_binary(user_id) and is_binary(device_id) do
    do_put(access_token, user_id, device_id, exp)
  end

  # Test-only seam, compile-time guarded (story oauth-legacy-coexistence, AC6): a 4-arity fun
  # `(jwt, user_id, device_id, exp)` called INSTEAD of the guarded INSERT; its value is `put/4`'s result.
  if Mix.env() == :test do
    defp do_put(access_token, user_id, device_id, exp) do
      case Application.get_env(:nebu_http, :device_binding_put_override) do
        fun when is_function(fun, 4) -> fun.(access_token, user_id, device_id, exp)
        _ -> insert_binding(access_token, user_id, device_id, exp)
      end
    end
  else
    defp do_put(access_token, user_id, device_id, exp), do: insert_binding(access_token, user_id, device_id, exp)
  end

  # Best-effort, mirroring `get_device/1`: an unavailable/missing
  # `jwt_device_bindings` table must NOT crash the login (or the lazy-bind during
  # /keys/upload). The worst case is that a later raw-JWT request resolves "no
  # bound device" and is handled exactly as an unbound token — never a 500.
  #
  # S3 F-1: `exp` (the verified JWT's exp, unix seconds) is persisted so the
  # device-delete kill-switch can denylist the bound token until its own expiry.
  # nil exp keeps the row resolvable but yields no kill-switch entry for that token.
  #
  # story oauth-token-endpoint (T25 b): a JWT is NEVER bound to a device that has an OAuth
  # session (`matrix_sessions.auth_api = 'oauth'`) — one guarded INSERT ... SELECT ... WHERE NOT
  # EXISTS. A refused binding stores no row and does not prime the cache. Story
  # oauth-legacy-coexistence (C11): the refusal is REPORTED (`{:error, :oauth_device}`) so callers can
  # refuse to act as that device; a database error stays best effort (`:ok`, unchanged).
  defp insert_binding(access_token, user_id, device_id, exp) do
    result =
      safe_query(
        """
        INSERT INTO jwt_device_bindings (token_hash, user_id, device_id, exp, created_at)
        SELECT $1::text, $2::text, $3::text, $4::bigint, $5::bigint
         WHERE NOT EXISTS (SELECT 1 FROM matrix_sessions
                            WHERE user_id = $2::text AND device_id = $3::text AND auth_api = 'oauth')
        ON CONFLICT (token_hash) DO UPDATE
          SET exp = COALESCE(EXCLUDED.exp, jwt_device_bindings.exp)
          WHERE jwt_device_bindings.user_id = EXCLUDED.user_id
            AND jwt_device_bindings.device_id = EXCLUDED.device_id
        """,
        [hash(access_token), user_id, device_id, exp, System.system_time(:millisecond)]
      )

    # Prime the read cache so a request that arrives within the TTL of a prior cached
    # MISS (e.g. an OTK-only top-up right after the first device_keys upload that
    # lazily bound this token) resolves the new device immediately, not nil.
    case result do
      {:ok, %{num_rows: 0}} ->
        cache_delete(hash(access_token))
        {:error, :oauth_device}

      _ ->
        cache_put(hash(access_token), {device_id, false})
        :ok
    end
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
    {:ok, device_id, _oauth_device?} = lookup(access_token)
    device_id
  end

  @doc """
  Like `get_device/1`, plus whether the binding is REFUSED: `{:ok, device_id | nil, refused? :: boolean}`
  (unbound => `{:ok, nil, false}`). `refused?` is true when the bound device has an OAuth session
  (story oauth-token-endpoint, T25 c) OR has NO `devices` row any more (story oauth-legacy-coexistence,
  C13 c: a JWT bound to a deleted device must not authenticate again, also on a node that never saw
  the denylist entry). Resolved in the SAME (cached, 60 s) query as the device; `OidcPlug` refuses a
  raw JWT whose binding is refused. Never raises.
  """
  @spec lookup(String.t()) :: {:ok, String.t() | nil, boolean()}
  def lookup(access_token) when is_binary(access_token) do
    h = hash(access_token)

    case cache_get(h) do
      {:hit, {device_id, oauth?}} ->
        {:ok, device_id, oauth?}

      _ ->
        case query_binding(h) do
          {:ok, {device_id, oauth?}} ->
            cache_put(h, {device_id, oauth?})
            {:ok, device_id, oauth?}

          # bugfix legacy-logout-per-device (Kassandra L2): a DATABASE ERROR is never cached. It degrades this
          # request to "no bound device" (as before), but the next request asks the database again instead of
          # treating a bound JWT as unbound for the whole TTL.
          :error ->
            {:ok, nil, false}
        end
    end
  end

  @doc """
  Like `lookup/1`, but ALWAYS reads the database (no cache read, no cache write) and reports a database error:
  `{:ok, device_id | nil, refused?}` or `{:error, :unavailable}`. For decisions that must not act on a stale or
  degraded answer: the legacy `POST /logout` of a JWT that `OidcPlug` resolved as unbound (bugfix
  legacy-logout-per-device, L2) re-asks here and fails closed (`500`) when the database cannot answer. Never raises.
  """
  @spec lookup_fresh(String.t()) :: {:ok, String.t() | nil, boolean()} | {:error, :unavailable}
  def lookup_fresh(access_token) when is_binary(access_token) do
    case query_binding(hash(access_token)) do
      {:ok, {device_id, oauth?}} -> {:ok, device_id, oauth?}
      :error -> {:error, :unavailable}
    end
  end

  # `{:ok, {device_id | nil, refused?}}` (no row = `{nil, false}`) or `:error` for a database failure.
  defp query_binding(h) do
    case safe_query(
           """
           SELECT b.device_id,
                  (EXISTS(SELECT 1 FROM matrix_sessions m
                           WHERE m.user_id = b.user_id AND m.device_id = b.device_id
                             AND m.auth_api = 'oauth')
                   OR NOT EXISTS(SELECT 1 FROM devices d
                                  WHERE d.user_id = b.user_id AND d.device_id = b.device_id))
             FROM jwt_device_bindings b
            WHERE b.token_hash = $1
           """,
           [h]
         ) do
      {:ok, %{rows: [[device_id, oauth?]]}} -> {:ok, {device_id, oauth? == true}}
      {:ok, %{rows: []}} -> {:ok, {nil, false}}
      _ -> :error
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
  The ONE JWT kill-switch of a device (story oauth-legacy-coexistence, C13 b): every raw-JWT binding of
  `(user_id, device_id)` is denylisted (`TokenDenylist.revoke_by_hash/2`) and ONLY the binding rows
  whose denylist DB write succeeded are deleted. A row that could not be confirmed (failed write, or no
  `exp`) is KEPT, so the JWT stays refused through the binding (`lookup/1`) on every node instead of
  turning into a working unbound credential: `{:error, :partial}` (a WARNING without token or hash is
  logged; HTTP callers keep their success answer, the teardown already committed). Option
  `except_hash:` — the preserved own-device credential of a fresh-UIA self-delete — is neither
  denylisted nor deleted. Never raises (an exception is `{:error, :partial}`).
  """
  @spec kill_device_jwts(String.t(), String.t(), keyword()) :: :ok | {:error, :partial}
  def kill_device_jwts(user_id, device_id, opts \\ []) when is_binary(user_id) and is_binary(device_id) do
    except = Keyword.get(opts, :except_hash)

    results =
      for {token_hash, exp} <- list_for_user_device(user_id, device_id), token_hash != except do
        case Nebu.Web.TokenDenylist.revoke_by_hash(token_hash, exp) do
          :ok ->
            delete_binding(token_hash)
            :ok

          {:error, _} ->
            :kept
        end
      end

    if Enum.all?(results, &(&1 == :ok)) do
      :ok
    else
      Logger.warning("device JWT kill-switch: a binding could not be denylisted and was kept")
      {:error, :partial}
    end
  rescue
    e ->
      Logger.warning("device JWT kill-switch failed: #{inspect(e.__struct__)}")
      {:error, :partial}
  catch
    :exit, _ ->
      Logger.warning("device JWT kill-switch exited")
      {:error, :partial}
  end

  defp delete_binding(token_hash) do
    cache_delete(token_hash)
    _ = safe_query("DELETE FROM jwt_device_bindings WHERE token_hash = $1", [token_hash])
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

  # ── per-node TTL cache (token_hash -> {{device_id | nil, oauth_device?}, cached_at_monotonic_ms}) ──
  # A bound token's device never changes, so a short TTL is safe and lifts the
  # per-request DB read off the /sync hot path. A `nil` (no binding) is cached too so
  # a forged/never-logged-in JWT does not hit the DB on every request either.
  @cache_table :nebu_jwt_device_binding_cache
  @cache_ttl_ms 60_000

  defp cache_get(hash) do
    ensure_table()

    case :ets.lookup(@cache_table, hash) do
      [{^hash, value, cached_at}] ->
        if now_ms() - cached_at < @cache_ttl_ms, do: {:hit, value}, else: :miss

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp cache_put(hash, value) do
    ensure_table()
    :ets.insert(@cache_table, {hash, value, now_ms()})
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
