defmodule Nebu.OAuth.AccountStore do
  @moduledoc """
  Persistence of the account-management page's sign-in flow state and browser sessions
  (`oauth_account_login_requests` and `oauth_account_sessions`, migration 000043) — epic oauth-broker,
  story oauth-account-management (A6, A8, A19, A23, A24).

  ADR-018: inline SQL, no ORM. ADR-020 (cluster safety): both tables are the ONLY state of the flow
  and the session, so any node can complete a sign-in and serve any request, and a node restart loses
  nothing (no ETS / GenServer / `persistent_term` decides anything here).

  ## Login requests (`insert_login_request/1`, `consume_login_request/1`)

  One row per `GET /account` / `GET /account/reauth` that starts an IdP login. The key is
  `state_hash` (lowercase hex SHA-256 of the `o2.acct.` state; the plaintext is never stored). Like
  `Nebu.OAuth.AuthzStore` the live-row soft cap sits INSIDE the INSERT
  (`INSERT ... SELECT ... WHERE (SELECT count(*) ...) < cap`; globally 10 000 live rows AND 300 per source
  (`source_key`), story oauth-dcr-abuse-hardening AH11 / gate item aa) and the consume is ONE atomic
  `DELETE ... RETURNING ..., (expires_at > now()) AS live`: of N concurrent callbacks for the same
  state exactly one gets the row. TTL 600 s (a CHECK of the table caps it).

  ## Browser sessions (`create_session/1`, `touch_session/1`, `delete_session/1`)

  A session is NOT a Matrix device. `session_hash` is the SHA-256 hex of a 256-bit random cookie value
  (the plaintext is never stored), `csrf_hash` the SHA-256 hex of the CSRF token. Lifetimes are code
  constants (idle #{900} s sliding, absolute #{3600} s, a CHECK caps the absolute one). `touch_session/1`
  is ONE atomic sliding `UPDATE ... WHERE session_hash = $1 AND idle_expires_at > now() AND
  expires_at > now() RETURNING ...` (idle and absolute timeouts are enforced in SQL, `auth_time`
  never changes). `create_session/1` runs in ONE transaction: it deletes the replaced session
  (session-fixation defence), inserts the new row and keeps at most #{20} sessions per user (the
  oldest ones are deleted: a user is never locked out, the table cannot grow per user).
  Sessions need no per-source cap (authenticated, 20 per user; gate item aa).

  ## Purge

  `purge_expired/0` deletes expired login requests and expired (idle or absolute) sessions in batches
  (the `Nebu.Workers.OAuthFlowPurgeWorker`, every 10 minutes). Housekeeping only: correctness never
  depends on it.

  Test seam: `:nebu_http, :oauth_repo` (same as `Nebu.OAuth.AuthzStore`).
  """

  @login_ttl_seconds 600
  @login_cap 10_000
  # Per-source cap (story oauth-dcr-abuse-hardening, AH11, gate item aa): at most this many live
  # login requests per `source_key` (`Nebu.OAuth.SourceKey`); the global cap stays as a memory bound.
  @source_login_cap 300
  @idle_seconds 900
  @absolute_seconds 3600
  @sessions_per_user 20

  @purge_batch 1000
  @purge_max_batches 20

  @sql_insert_login """
  INSERT INTO oauth_account_login_requests
    (state_hash, idp_verifier_enc, idp_nonce, binding_hash, return_action, return_device_id,
     replaces_session_hash, created_at, expires_at, source_key)
  SELECT $1::text, $2::text, $3::text, $4::text, $5::text, $6::text, $7::text, now(),
         now() + ($8::int * interval '1 second'), $10::text
  WHERE (SELECT count(*) FROM oauth_account_login_requests WHERE expires_at > now()) < $9::bigint
    AND ($10::text IS NULL
         OR (SELECT count(*) FROM oauth_account_login_requests
             WHERE source_key = $10::text AND expires_at > now()) < $11::bigint)
  """

  @sql_source_live "SELECT count(*) FROM oauth_account_login_requests WHERE source_key = $1::text AND expires_at > now()"

  @sql_consume_login """
  DELETE FROM oauth_account_login_requests WHERE state_hash = $1
  RETURNING idp_verifier_enc, idp_nonce, binding_hash, return_action, return_device_id,
            replaces_session_hash, created_at, (expires_at > now()) AS live
  """

  @sql_delete_session "DELETE FROM oauth_account_sessions WHERE session_hash = $1"

  @sql_insert_session """
  INSERT INTO oauth_account_sessions
    (session_hash, user_id, auth_time, csrf_hash, created_at, last_seen_at, idle_expires_at, expires_at)
  VALUES ($1, $2, $3, $4, now(), now(), now() + ($5::int * interval '1 second'),
          now() + ($6::int * interval '1 second'))
  """

  # Keeps the newest N sessions of the user (the 21st login deletes the oldest).
  @sql_trim_sessions """
  DELETE FROM oauth_account_sessions
  WHERE session_hash IN (
    SELECT session_hash FROM oauth_account_sessions
    WHERE user_id = $1
    ORDER BY created_at DESC, session_hash
    OFFSET $2
  )
  """

  @sql_touch """
  UPDATE oauth_account_sessions
     SET last_seen_at = now(),
         idle_expires_at = LEAST(now() + ($2::int * interval '1 second'), expires_at)
   WHERE session_hash = $1 AND idle_expires_at > now() AND expires_at > now()
  RETURNING user_id, auth_time, csrf_hash
  """

  # No `FOR UPDATE SKIP LOCKED` (see `Nebu.OAuth.AuthzStore`): concurrent purgers are still safe.
  @sql_purge_login """
  DELETE FROM oauth_account_login_requests
  WHERE state_hash IN (
    SELECT state_hash FROM oauth_account_login_requests
    WHERE expires_at < now()
    ORDER BY expires_at
    LIMIT $1
  )
  """

  @sql_purge_sessions """
  DELETE FROM oauth_account_sessions
  WHERE session_hash IN (
    SELECT session_hash FROM oauth_account_sessions
    WHERE expires_at < now() OR idle_expires_at < now()
    ORDER BY expires_at
    LIMIT $1
  )
  """

  @doc "Lowercase hex SHA-256 — the row key of a state, a session cookie, a CSRF token or a binding cookie."
  @spec hash(String.t()) :: String.t()
  def hash(value) when is_binary(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  @doc "A fresh random value: 32 random bytes, base64url without padding (43 characters)."
  @spec random_token() :: String.t()
  def random_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

  # ── login requests ──────────────────────────────────────────────────────────

  @doc """
  Persists a login request: `attrs` carries `:state_hash`, `:idp_verifier_enc`, `:idp_nonce`,
  `:binding_hash` and optionally `:return_action` (nil = the default page), `:return_device_id`,
  `:replaces_session_hash`, `:source_key` (`Nebu.OAuth.SourceKey.for_conn/1`; `nil` = no source = not
  counted per source).

  `:ok`, `{:error, :capacity}` when #{@login_cap} live requests exist overall or #{@source_login_cap}
  of the same source (`:cap` / `:source_cap` seams; nothing is evicted to make room),
  `{:error, :invalid}` when PostgreSQL refuses a value as data, `{:error, reason}` otherwise.
  """
  @spec insert_login_request(map()) :: :ok | {:error, :capacity | :invalid | term()}
  def insert_login_request(%{state_hash: state_hash} = attrs) do
    params = [
      state_hash,
      attrs.idp_verifier_enc,
      attrs.idp_nonce,
      attrs.binding_hash,
      Map.get(attrs, :return_action),
      Map.get(attrs, :return_device_id),
      Map.get(attrs, :replaces_session_hash),
      @login_ttl_seconds,
      Map.get(attrs, :cap, @login_cap),
      Map.get(attrs, :source_key),
      Map.get(attrs, :source_cap, @source_login_cap)
    ]

    case query(@sql_insert_login, params) do
      {:ok, %{num_rows: 1}} -> :ok
      {:ok, %{num_rows: 0}} -> {:error, :capacity}
      {:error, %Postgrex.Error{postgres: %{pg_code: "22" <> _}}} -> {:error, :invalid}
      {:error, %Postgrex.Error{postgres: %{pg_code: "23" <> _}}} -> {:error, :invalid}
      {:error, %DBConnection.EncodeError{}} -> {:error, :invalid}
      {:error, _} = error -> error
    end
  end

  @doc """
  `true` when `source_key` currently has at least the per-source cap of live login requests (lets the
  caller tell a PER-SOURCE refusal from the global cap after `{:error, :capacity}`; log wording only;
  `false` for `nil` or an unreadable count). Same `:source_cap` seam as `insert_login_request/1`.
  """
  @spec source_capped?(String.t() | nil, keyword()) :: boolean()
  def source_capped?(source_key, opts \\ [])
  def source_capped?(nil, _opts), do: false

  def source_capped?(source_key, opts) when is_binary(source_key) do
    case query(@sql_source_live, [source_key]) do
      {:ok, %{rows: [[n]]}} -> n >= Keyword.get(opts, :source_cap, @source_login_cap)
      _ -> false
    end
  end

  @doc """
  Atomically consumes the login request of an `o2.acct.` `state`: `{:ok, row}` (atom keys:
  `idp_verifier_enc`, `idp_nonce`, `binding_hash`, `return_action`, `return_device_id`,
  `replaces_session_hash`, `created_at` as unix seconds), `{:error, :expired}`
  (the row existed but was expired; consumed anyway), `{:error, :not_found}` (unknown or already
  consumed) or `{:error, :storage}`.
  """
  @spec consume_login_request(String.t()) :: {:ok, map()} | {:error, :expired | :not_found | :storage}
  def consume_login_request(state) when is_binary(state) do
    case query(@sql_consume_login, [hash(state)]) do
      {:ok, %{rows: [[enc, nonce, binding, action, device_id, replaces, created_at, live]]}} ->
        row = %{
          idp_verifier_enc: enc,
          idp_nonce: nonce,
          binding_hash: binding,
          return_action: action,
          return_device_id: device_id,
          replaces_session_hash: replaces,
          created_at: unix(created_at)
        }

        if live, do: {:ok, row}, else: {:error, :expired}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, _} ->
        {:error, :storage}
    end
  end

  defp unix(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp unix(%NaiveDateTime{} = dt), do: dt |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()

  # ── browser sessions ────────────────────────────────────────────────────────

  @doc """
  Creates a session (ONE transaction): deletes every session named in `:replaces` (a list of session
  hashes: the presented old cookie, rotation), inserts the new row and trims the user to the newest
  #{@sessions_per_user} sessions. `attrs`: `:session_hash`, `:user_id`, `:auth_time` (unix seconds, or `nil` when the IdP reported none: a session that is never fresh,
  story oauth-authorize-freshness FR14, migration 000045),
  `:csrf_hash`, `:replaces` (default `[]`). `:ok` or `{:error, reason}`.
  """
  @spec create_session(map()) :: :ok | {:error, term()}
  def create_session(%{session_hash: session_hash, user_id: user_id, auth_time: auth_time, csrf_hash: csrf_hash} = attrs) do
    replaces = attrs |> Map.get(:replaces, []) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    result =
      transaction(fn repo ->
        for old <- replaces, do: run!(repo, @sql_delete_session, [old])
        run!(repo, @sql_insert_session, [session_hash, user_id, auth_time, csrf_hash, @idle_seconds, @absolute_seconds])
        run!(repo, @sql_trim_sessions, [user_id, @sessions_per_user])
        :ok
      end)

    case result do
      {:ok, :ok} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  The sliding session lookup (ONE atomic UPDATE, A8): `{:ok, %{user_id:, auth_time: integer | nil, csrf_hash:}}` for
  a live session (idle AND absolute timeout checked in SQL; `idle_expires_at` slides, never beyond
  `expires_at`), `:none` for an unknown / expired one, `{:error, :storage}` when the database cannot
  be read.
  """
  @spec touch_session(String.t()) :: {:ok, map()} | :none | {:error, :storage}
  def touch_session(session_hash) when is_binary(session_hash) do
    case query(@sql_touch, [session_hash, @idle_seconds]) do
      {:ok, %{rows: [[user_id, auth_time, csrf_hash]]}} -> {:ok, %{user_id: user_id, auth_time: auth_time, csrf_hash: csrf_hash}}
      {:ok, %{rows: []}} -> :none
      {:error, _} -> {:error, :storage}
    end
  end

  @doc "Deletes a session by its hash (logout, deactivated user). `:ok` or `{:error, reason}`."
  @spec delete_session(String.t()) :: :ok | {:error, term()}
  def delete_session(session_hash) when is_binary(session_hash) do
    case query(@sql_delete_session, [session_hash]) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  # ── purge ───────────────────────────────────────────────────────────────────

  @doc """
  Deletes expired login requests and expired (idle or absolute) sessions in batches of #{@purge_batch}
  (at most #{@purge_max_batches} batches each per call). `{:ok, %{login_requests: n, sessions: m}}` or
  `{:error, reason}`.
  """
  @spec purge_expired() :: {:ok, %{login_requests: non_neg_integer(), sessions: non_neg_integer()}} | {:error, term()}
  def purge_expired do
    with {:ok, requests} <- do_purge(@sql_purge_login, 0, 0),
         {:ok, sessions} <- do_purge(@sql_purge_sessions, 0, 0) do
      {:ok, %{login_requests: requests, sessions: sessions}}
    end
  end

  defp do_purge(_sql, total, @purge_max_batches), do: {:ok, total}

  defp do_purge(sql, total, batches) do
    case query(sql, [@purge_batch]) do
      {:ok, %{num_rows: n}} when n >= @purge_batch -> do_purge(sql, total + n, batches + 1)
      {:ok, %{num_rows: n}} -> {:ok, total + n}
      # another purger (other node) is deleting the same batch right now: leave it to that one
      {:error, %Postgrex.Error{postgres: %{code: :deadlock_detected}}} -> {:ok, total}
      {:error, _} = error -> error
    end
  end

  # ── plumbing ────────────────────────────────────────────────────────────────

  defp repo, do: Application.get_env(:nebu_http, :oauth_repo, Nebu.Repo)

  defp query(sql, params) do
    Ecto.Adapters.SQL.query(repo(), sql, params)
  rescue
    e in [RuntimeError, ArgumentError, UndefinedFunctionError, DBConnection.ConnectionError, DBConnection.EncodeError] ->
      {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp run!(repo, sql, params) do
    case Ecto.Adapters.SQL.query(repo, sql, params) do
      {:ok, result} -> result
      {:error, error} -> repo.rollback(error)
    end
  end

  defp transaction(fun) do
    repo = repo()
    repo.transaction(fn -> fun.(repo) end)
  rescue
    e in [RuntimeError, ArgumentError, UndefinedFunctionError, DBConnection.ConnectionError, DBConnection.EncodeError] ->
      {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end
end
