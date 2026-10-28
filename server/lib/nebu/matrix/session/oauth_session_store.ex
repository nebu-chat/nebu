defmodule Nebu.Matrix.Session.OAuthSessionStore do
  @moduledoc """
  OAuth sessions in `matrix_sessions` (`auth_api = 'oauth'`, migration 000042) — story
  oauth-token-endpoint (epic oauth-broker), T2 / T3 / T7 / T8 / T10 / T11 / T27. Matrix domain,
  inline SQL (ADR-018); reached from the OAuth domain only through the `Nebu.Matrix` facade
  (`oauth_*` functions, ADR-020) via `Nebu.Matrix.OAuthSession`.

  ## Row model (T2, T3)

  Identical to the legacy rows of `Nebu.Matrix.Session.MatrixSessionStore`: one row per token
  pair, keyed by `access_token_hash`, `refresh_token_hash` UNIQUE (only SHA-256 hashes of the
  opaque tokens are stored, `MatrixSessionStore.hash_token/1`); a session = all rows of
  `(user_id, device_id)`; at most one `revoked_at IS NULL` row per device. OAuth rows additionally
  carry `client_id`, `scope` (the granted scope string), `session_expires_at` (absolute session
  maximum, copied VERBATIM on every rotation, never extended) and `oauth_code_hash` (T8, copied on
  every rotation). `expires_at` is the ACCESS-token expiry (`LEAST(now() + ttl,
  session_expires_at)`), so `OidcPlug` answers an expired access token with `soft_logout` without
  any change; a refresh is allowed while `session_expires_at > now()`.

  ## Refresh-Retry (T10, the legacy 0c semantics)

  `rotate/1` soft-revokes the active row (`grace_until = NULL` = PENDING), consumes the pending
  siblings when the CURRENT refresh token was redeemed, and inserts the new row — in ONE
  transaction, guarded by `revoked_at IS NULL` (exactly one winner across the cluster). A replay of a
  pending refresh token re-validates its row `FOR UPDATE` inside the transaction. PENDING vs
  CONSUMED is decided ONLY by `grace_until IS NULL` / `IS NOT NULL` (Postgres `now()` is the
  transaction start). Sibling updates lock in `access_token_hash` order.

  Every query filters `auth_api = 'oauth'` (T27): a legacy refresh token is unknown here.

  ## Revocation (story oauth-token-revocation-logout)

  `end_session_for_token/1`, `end_device/2` and `oauth_device_ids/1` end a whole session: one transaction
  under the `devices` row lock issuance and rotation take (lock order devices -> matrix_sessions), every
  `matrix_sessions` row of the device (any `auth_api`) and the device tables are deleted. The token lookup
  has no state filter (either token, any state); the store takes the PLAINTEXT token and hashes it once.

  ## Device holder and IdP refresh lease (story oauth-authorize-freshness, FR11, FR15)

  `device_session/2` is the one-device variant of `device_sessions/1` (who holds a device id: the consent
  page and the Allow check). `claim_lease/4` / `release_lease/3` serialize the IdP leg of a `per_refresh`
  refresh of one device across the cluster through a ROW in `oauth_idp_refresh_leases` (migration
  000045), NOT a transaction-scoped advisory lock: every statement is its own autocommit, so no pool
  connection and no transaction is held across the IdP HTTP call. A crashed holder's lease simply expires.

  Test seam (compiled in only for `MIX_ENV=test`): `:nebu_http, :oauth_session_repo` replaces the
  repo module (default `Nebu.Repo`).
  """

  alias Nebu.Matrix.Session.MatrixSessionStore

  defmodule DeadlockError do
    @moduledoc "A statement of the session store was chosen as the victim of a deadlock (SQLSTATE 40P01): the caller may retry."
    defexception message: "oauth session store: deadlock detected"
  end

  @columns "access_token_hash, refresh_token_hash, oidc_refresh_token, user_id, device_id, expires_at, " <>
             "revoked_at, grace_until, client_id, scope, session_expires_at, auth_time, oauth_code_hash"

  @type session :: %{
          access_token_hash: String.t(),
          refresh_token_hash: String.t(),
          oidc_refresh_token: String.t() | nil,
          user_id: String.t(),
          device_id: String.t(),
          expires_at: DateTime.t(),
          revoked_at: DateTime.t() | nil,
          grace_until: DateTime.t() | nil,
          client_id: String.t(),
          scope: String.t(),
          session_expires_at: DateTime.t(),
          auth_time: integer() | nil,
          oauth_code_hash: String.t() | nil
        }

  # ── reads ───────────────────────────────────────────────────────────────────

  @doc """
  Error-aware `users.is_active` read (T19): `{:ok, true}` active, `{:ok, false}` deactivated, erased
  (`deletion_status IS NOT NULL`, story gdpr-erasure-global-data D17) or unknown, `{:error, reason}`
  when the database could not be read.
  """
  @spec user_active(String.t()) :: {:ok, boolean()} | {:error, term()}
  def user_active(user_id) when is_binary(user_id) do
    case query("SELECT (is_active AND deletion_status IS NULL) FROM users WHERE user_id = $1", [user_id]) do
      {:ok, %{rows: [[true]]}} -> {:ok, true}
      {:ok, %{rows: _}} -> {:ok, false}
      {:error, _} = error -> error
    end
  end

  @doc """
  Classifies a presented OAuth refresh token (T10, T11):

    * `{:ok, active_row, :current}` — the device's active row, session alive.
    * `{:ok, active_row, :replay}` — a rotated-away but PENDING token (lost response): served by
      rotating the device's ACTIVE row again.
    * `{:reused, row}` — a CONSUMED token while the session is alive (an active row exists).
    * `:error` — unknown, legacy, an access token, the session expired or no active row.
    * `{:error, :unavailable}` — the database could not be read.
  """
  @spec resolve_refresh_token(String.t()) ::
          {:ok, session(), :current | :replay} | {:reused, session()} | :error | {:error, :unavailable}
  def resolve_refresh_token(refresh_token) when is_binary(refresh_token) do
    sql = """
    SELECT #{@columns},
           (session_expires_at > now()),
           EXISTS(SELECT 1 FROM matrix_sessions a
                   WHERE a.user_id = m.user_id AND a.device_id = m.device_id
                     AND a.auth_api = 'oauth' AND a.revoked_at IS NULL
                     AND a.session_expires_at > now())
      FROM matrix_sessions m
     WHERE m.refresh_token_hash = $1 AND m.auth_api = 'oauth'
    """

    case query(sql, [MatrixSessionStore.hash_token(refresh_token)]) do
      {:ok, %{rows: []}} ->
        :error

      {:ok, %{rows: [row]}} ->
        {alive?, row} = List.pop_at(row, 13)
        {has_active?, row} = List.pop_at(row, 13)
        sess = to_session(row)

        cond do
          is_nil(sess.revoked_at) and alive? -> {:ok, sess, :current}
          is_nil(sess.revoked_at) -> :error
          not is_nil(sess.grace_until) and alive? and has_active? -> {:reused, sess}
          not is_nil(sess.grace_until) -> :error
          true -> active_row(sess.user_id, sess.device_id, :replay)
        end

      _ ->
        {:error, :unavailable}
    end
  end

  @doc """
  The device's active, alive OAuth row (T28 re-read): `{:ok, row}`, `:none` or
  `{:error, :unavailable}`.
  """
  @spec active_row(String.t(), String.t()) :: {:ok, session()} | :none | {:error, :unavailable}
  def active_row(user_id, device_id) do
    case active_row(user_id, device_id, :plain) do
      {:ok, row, :plain} -> {:ok, row}
      :error -> :none
      other -> other
    end
  end

  defp active_row(user_id, device_id, tag) do
    sql = """
    SELECT #{@columns} FROM matrix_sessions
     WHERE user_id = $1 AND device_id = $2 AND auth_api = 'oauth'
       AND revoked_at IS NULL AND session_expires_at > now()
     ORDER BY created_at DESC
     LIMIT 1
    """

    case query(sql, [user_id, device_id]) do
      {:ok, %{rows: [row]}} -> {:ok, to_session(row), tag}
      {:ok, %{rows: []}} -> :error
      _ -> {:error, :unavailable}
    end
  end

  # ── writes ──────────────────────────────────────────────────────────────────

  @doc """
  T7 issuance in ONE transaction: upserts the `devices` row (it exists afterwards; its row lock
  also serializes concurrent issuances for the same device), deletes EVERY `matrix_sessions` row
  of `(user_id, device_id)` (legacy AND oauth: all previous tokens of a reused device are revoked)
  and inserts the new OAuth row. Returns `{:ok, expires_in}` (whole seconds until `expires_at`,
  computed from the SAME `now()` as `expires_at`, T33) or `{:error, reason}` (rolled back).

  `attrs`: `access_token`, `refresh_token` (plaintext; only hashes are stored), `user_id`,
  `device_id`, `client_id`, `scope`, `oauth_code_hash`, `idp_rt_enc` (ciphertext or nil),
  `auth_time` (unix seconds or nil), `access_ttl_seconds`, `session_ttl_seconds`.
  """
  @spec insert_replacing_device(map()) :: {:ok, pos_integer()} | {:error, term()}
  def insert_replacing_device(attrs) do
    repo = repo()

    repo.transaction(fn ->
      # story oauth-client-revocation CR5: the client row is locked FOR SHARE as the FIRST statement (lock order
      # oauth_clients -> devices -> matrix_sessions, the revoke's order): a revoke that committed first is seen
      # here as `revoked`, one that has not committed yet blocks until this issuance committed (its teardown
      # then deletes the new session).
      lock_client!(repo, attrs.client_id)

      :ok =
        Nebu.Matrix.DeviceKeyStore.upsert_device(attrs.user_id, attrs.device_id,
          display_name: nil,
          last_seen_ts: System.system_time(:millisecond),
          last_seen_ip: nil
        )

      # story oauth-authorize-freshness L-1: UNDER the devices row lock (the upsert above), a live session of
      # ANOTHER app than the one the user accepted at consent refuses the issuance (the whole transaction rolls back)
      if Map.get(attrs, :device_holder_checked, false), do: check_holder!(repo, attrs)

      {:ok, _} =
        query!("DELETE FROM matrix_sessions WHERE user_id = $1 AND device_id = $2", [attrs.user_id, attrs.device_id])

      {:ok, %{rows: [[expires_in]]}} =
        query!(
          """
          INSERT INTO matrix_sessions
            (access_token_hash, refresh_token_hash, oidc_refresh_token, user_id, device_id, expires_at,
             session_expires_at, auth_time, auth_api, client_id, scope, oauth_code_hash, created_at)
          VALUES ($1, $2, $3, $4, $5,
                  LEAST(now() + ($6::bigint * interval '1 second'), now() + ($7::bigint * interval '1 second')),
                  now() + ($7::bigint * interval '1 second'), $8, 'oauth', $9, $10, $11, now())
          RETURNING GREATEST(1, floor(extract(epoch FROM expires_at - now())))::bigint
          """,
          [
            MatrixSessionStore.hash_token(attrs.access_token),
            MatrixSessionStore.hash_token(attrs.refresh_token),
            attrs.idp_rt_enc,
            attrs.user_id,
            attrs.device_id,
            attrs.access_ttl_seconds,
            attrs.session_ttl_seconds,
            attrs.auth_time,
            attrs.client_id,
            attrs.scope,
            attrs.oauth_code_hash
          ]
        )

      expires_in
    end)
  rescue
    e -> {:error, {:exception, e.__struct__}}
  catch
    :exit, _ -> {:error, :exit}
  end

  # `rollback(:device_in_use)` unless the newest live row of the device is legacy / absent, or an OAuth row of
  # the redeeming client or of the holder the user saw at Allow (`expected_holder_client_id`).
  defp check_holder!(repo, attrs) do
    {:ok, %{rows: rows}} =
      query!(
        """
        SELECT auth_api, client_id FROM matrix_sessions
         WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL
         ORDER BY created_at DESC LIMIT 1
        """,
        [attrs.user_id, attrs.device_id]
      )

    case rows do
      [["oauth", holder]] when holder != attrs.client_id ->
        if holder == Map.get(attrs, :expected_holder_client_id), do: :ok, else: repo.rollback(:device_in_use)

      _ ->
        :ok
    end
  end

  @doc """
  T10 rotation of the ACTIVE row `active_access_token_hash` (one transaction). `params`:
  `active_access_token_hash` (read from the DB, never client input), `new_access_token`,
  `new_refresh_token`, `access_ttl_seconds`, `scope` (the new granted scope), optional
  `new_oidc_refresh_token` (ciphertext; nil keeps the stored one), `consume_pending_siblings`
  (redeemed the CURRENT token), optional `replay_refresh_token` (the presented pending token,
  re-validated `FOR UPDATE`).

  `{:ok, expires_in}`; `:error` when the row is no longer the alive active row (lost race:
  re-resolve); `{:error, :consumed}` when the replayed token was consumed meanwhile (reuse).
  """
  @spec rotate(map()) :: {:ok, pos_integer()} | :error | {:error, :consumed}
  def rotate(params) do
    repo = repo()
    old_h = Map.fetch!(params, :active_access_token_hash)

    txn =
      repo.transaction(fn ->
        lock_client_and_device_of(repo, old_h)

        case query!(
               """
               UPDATE matrix_sessions
                  SET revoked_at = now(), grace_until = NULL
                WHERE access_token_hash = $1 AND revoked_at IS NULL AND auth_api = 'oauth'
                  AND session_expires_at > now()
               RETURNING user_id, device_id, oidc_refresh_token, auth_time, client_id, scope,
                         session_expires_at, oauth_code_hash
               """,
               [old_h]
             ) do
          {:ok, %{rows: []}} ->
            repo.rollback(:not_found)

          {:ok, %{rows: [[user_id, device_id, old_oidc_rt, auth_time, client_id, old_scope, session_exp, code_hash]]}} ->
            case Map.get(params, :replay_refresh_token) do
              nil ->
                :ok

              replay_rt ->
                case query!(
                       """
                       SELECT 1 FROM matrix_sessions
                        WHERE refresh_token_hash = $1 AND auth_api = 'oauth'
                          AND revoked_at IS NOT NULL AND grace_until IS NULL
                          FOR UPDATE
                       """,
                       [MatrixSessionStore.hash_token(replay_rt)]
                     ) do
                  {:ok, %{num_rows: 0}} -> repo.rollback(:consumed)
                  {:ok, _} -> :ok
                end
            end

            if Map.get(params, :consume_pending_siblings, false) do
              {:ok, _} =
                query!(
                  """
                  UPDATE matrix_sessions
                     SET grace_until = now()
                   WHERE access_token_hash IN (
                           SELECT access_token_hash FROM matrix_sessions
                            WHERE user_id = $1 AND device_id = $2 AND auth_api = 'oauth'
                              AND access_token_hash != $3
                              AND revoked_at IS NOT NULL
                              AND grace_until IS NULL
                            ORDER BY access_token_hash
                              FOR UPDATE)
                  """,
                  [user_id, device_id, old_h]
                )
            end

            {:ok, %{rows: [[expires_in]]}} =
              query!(
                """
                INSERT INTO matrix_sessions
                  (access_token_hash, refresh_token_hash, oidc_refresh_token, user_id, device_id, expires_at,
                   session_expires_at, auth_time, auth_api, client_id, scope, oauth_code_hash, created_at)
                VALUES ($1, $2, $3, $4, $5, LEAST(now() + ($6::bigint * interval '1 second'), $7::timestamptz),
                        $7::timestamptz, $8, 'oauth', $9, $10, $11, now())
                RETURNING GREATEST(1, floor(extract(epoch FROM expires_at - now())))::bigint
                """,
                [
                  MatrixSessionStore.hash_token(params.new_access_token),
                  MatrixSessionStore.hash_token(params.new_refresh_token),
                  Map.get(params, :new_oidc_refresh_token) || old_oidc_rt,
                  user_id,
                  device_id,
                  params.access_ttl_seconds,
                  session_exp,
                  auth_time,
                  client_id,
                  Map.get(params, :scope) || old_scope,
                  code_hash
                ]
              )

            expires_in
        end
      end)

    case txn do
      {:ok, expires_in} -> {:ok, expires_in}
      {:error, :not_found} -> :error
      {:error, :consumed} -> {:error, :consumed}
      {:error, :client_not_approved} -> {:error, :client_not_approved}
      {:error, :client_locked} -> {:error, :client_locked}
    end
  end

  # Review cycle 1 (MINOR 2): a rotation takes the SAME `devices` row lock the issuance upsert takes
  # (`insert_replacing_device/1`: lock first, then delete + insert), so a re-login on the device cannot
  # interleave with a concurrent rotation and leave a surviving active row. After the lock the
  # guarded UPDATE below re-evaluates `revoked_at IS NULL`: when the issuance deleted the rows
  # meanwhile it matches 0 rows (`:error`, the caller re-resolves). Lock order is always
  # oauth_clients row (FOR SHARE, story oauth-client-revocation CR5) -> devices row -> matrix_sessions rows.
  # A missing devices row (deleted device) simply locks nothing.
  defp lock_client_and_device_of(repo, active_access_token_hash) do
    case query!("SELECT user_id, device_id, client_id FROM matrix_sessions WHERE access_token_hash = $1", [active_access_token_hash]) do
      {:ok, %{rows: [[user_id, device_id, client_id]]}} when is_binary(client_id) ->
        lock_client!(repo, client_id)
        query!("SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [user_id, device_id])
        :ok

      _ ->
        repo.rollback(:not_found)
    end
  end

  # CR5: `FOR SHARE` conflicts with the revoke's status UPDATE (row lock FOR NO KEY UPDATE). READ COMMITTED
  # re-reads the locked row after waiting, so a revoke that committed meanwhile is seen as `revoked`. The only
  # statement of the revocation side that touches another table is the one coupling the 000042 FK already has
  # (ADR-020 note in ADR-033): one OAuth column read, inline here (ADR-018).
  #
  # A revoke holds the client row for the whole teardown (up to its 120 s timeout): without a bound every token and
  # refresh request of that client would wait HERE holding a pool connection (pool 10) and the whole server would
  # answer 503 (Kassandra M-2). The wait is therefore bounded to 300 ms (`SET LOCAL lock_timeout`, reset right after
  # the lock) and a timeout rolls back as `:client_locked`, which the callers map to `unavailable` (503 +
  # Retry-After, the client retries).
  @client_lock_timeout "300ms"
  # The request-path teardowns (`/oauth2/revoke`, `/logout/all`, account page; G3-1 M-1) use the short bound of the lease
  # claim: the legacy `/logout` keeps its 2 s (story legacy-logout-per-device LL3).
  @request_device_lock_timeout "300ms"

  defp lock_client!(repo, client_id) do
    query!(repo, "SET LOCAL lock_timeout = '#{@client_lock_timeout}'", [])

    case Ecto.Adapters.SQL.query(repo, "SELECT status FROM oauth_clients WHERE client_id = $1 FOR SHARE", [client_id]) do
      {:ok, %{rows: [["approved"]]}} -> :ok
      {:ok, _} -> repo.rollback(:client_not_approved)
      {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} -> repo.rollback(:client_locked)
      {:error, %Postgrex.Error{postgres: %{code: :deadlock_detected}}} -> raise DeadlockError
      {:error, _} -> raise DBConnection.ConnectionError, "oauth session store query failed"
    end

    query!(repo, "SET LOCAL lock_timeout = DEFAULT", [])
    run_lock_hook()
  end

  # Test seam (compile-guarded, `:nebu_http, :oauth_session_lock_hook`, 0-arity): runs right after the client lock,
  # inside the transaction, in the caller's process (story oauth-client-revocation, race tests).
  if Mix.env() == :test do
    defp run_lock_hook do
      case Application.get_env(:nebu_http, :oauth_session_lock_hook) do
        fun when is_function(fun, 0) -> fun.()
        _ -> :ok
      end
    end
  else
    defp run_lock_hook, do: :ok
  end

  # ── revocation (story oauth-token-revocation-logout, R2 / R3 / R11) ─────────────────────

  @doc """
  Every device id of the user that has a `devices` row OR a `matrix_sessions` row of ANY `auth_api`
  (`/logout/all`, R17): the union is read in one checked statement, ordered. `{:ok, [device_id]} | {:error, reason}`.
  """
  @spec all_device_ids(String.t(), module()) :: {:ok, [String.t()]} | {:error, term()}
  def all_device_ids(user_id, repo \\ repo()) when is_binary(user_id) do
    sql = """
    SELECT device_id FROM devices WHERE user_id = $1
    UNION
    SELECT device_id FROM matrix_sessions WHERE user_id = $1
    ORDER BY device_id
    """

    case query(repo, sql, [user_id]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [d] -> d end)}
      {:error, _} = error -> error
    end
  end

  @sql_find_by_token """
  SELECT user_id, device_id, client_id FROM matrix_sessions
   WHERE (access_token_hash = $1 OR refresh_token_hash = $1) AND auth_api = 'oauth'
   LIMIT 1
  """

  @sql_recheck_token """
  SELECT 1 FROM matrix_sessions
   WHERE (access_token_hash = $1 OR refresh_token_hash = $1) AND auth_api = 'oauth'
     AND user_id = $2 AND device_id = $3
  """

  @doc """
  The ONE revocation transaction (R11), plaintext token in (hashed here, once; the pass-the-hash
  rule: callers never pass a hash):

    1. a PLAIN SELECT (no row lock) of `user_id, device_id, client_id` of the row whose
       `access_token_hash` OR `refresh_token_hash` equals the hash, `auth_api = 'oauth'`, WITHOUT any
       state filter (R3: active, expired, superseded, pending/consumed, expired session); no row =>
       `{:ok, :unknown}`, nothing locked;
    2. `SELECT 1 FROM devices ... FOR UPDATE` — the SAME row lock issuance (`insert_replacing_device/1`)
       and rotation (`rotate/1`) take (lock order devices -> matrix_sessions);
    3. re-check AFTER the lock that the presented token still has an OAuth row of that device (a T7
       re-login may have replaced the session meanwhile: then nothing is deleted, the NEW session
       survives);
    4. `DELETE` every `matrix_sessions` row of the device (a new statement: under READ COMMITTED its
       snapshot includes a rotation that committed while we waited for the lock);
    5. the device tables, inside the transaction (`DeviceKeyStore.delete_device!/3`: Trap 3).

  `{:ok, :revoked, %{user_id:, device_id:, client_id:}}` (the STORED client id), `{:ok, :unknown}` or
  `{:error, reason}` (rolled back). Never raises.
  """
  @spec end_session_for_token(String.t()) ::
          {:ok, :revoked, %{user_id: String.t(), device_id: String.t(), client_id: String.t()}}
          | {:ok, :unknown}
          | {:error, term()}
  def end_session_for_token(token) when is_binary(token) do
    repo = repo()
    h = MatrixSessionStore.hash_token(token)

    txn =
      repo.transaction(fn ->
        case query!(@sql_find_by_token, [h]) do
          {:ok, %{rows: []}} ->
            :unknown

          {:ok, %{rows: [[user_id, device_id, client_id] | _]}} ->
            # a request path (`/oauth2/revoke`): bounded like the lease claim (`:lock_timeout` rolls back, G3-1 M-1)
            lock_device_bounded!(repo, user_id, device_id, @request_device_lock_timeout)

            case query!(@sql_recheck_token, [h, user_id, device_id]) do
              {:ok, %{rows: []}} ->
                :unknown

              {:ok, _} ->
                delete_device_rows!(repo, user_id, device_id)
                {:revoked, %{user_id: user_id, device_id: device_id, client_id: client_id}}
            end
        end
      end)

    case txn do
      {:ok, :unknown} -> {:ok, :unknown}
      {:ok, {:revoked, info}} -> {:ok, :revoked, info}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:exception, e.__struct__}}
  catch
    :exit, _ -> {:error, :exit}
  end

  @doc """
  Ends the whole session of a device WITHOUT a token re-check (`/logout/all`, R17): lock the
  `devices` row, delete every `matrix_sessions` row of `(user_id, device_id)` (any `auth_api`) and the
  device tables, in one transaction. `:ok | {:error, reason}`; never raises.

  `opts[:bounded?]` (default `true`, every request path: `/logout/all`, the account page, `/oauth2/revoke`'s device
  teardown): the devices-row lock waits at most 300 ms (`SET LOCAL lock_timeout`), a timeout rolls back as
  `{:error, :lock_timeout}` (the facades answer unavailable / 503: a long client revoke holds the rows and a request
  must not park a pool connection behind it, G3-1 M-1). The client revoke's OWN teardown (`end_client_devices/2`)
  passes `bounded?: false`: it must lock, it holds the rows by design.
  """
  @spec end_device(String.t(), String.t(), module(), keyword()) :: :ok | {:error, term()}
  def end_device(user_id, device_id, repo \\ repo(), opts \\ []) when is_binary(user_id) and is_binary(device_id) do
    bounded? = Keyword.get(opts, :bounded?, true)

    txn =
      repo.transaction(fn ->
        if bounded?,
          do: lock_device_bounded!(repo, user_id, device_id, @request_device_lock_timeout),
          else: lock_device(repo, user_id, device_id)

        delete_device_rows!(repo, user_id, device_id)
        :ok
      end)

    case txn do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    _e in DeadlockError -> {:error, :deadlock}
    e -> if deadlock?(e), do: {:error, :deadlock}, else: {:error, {:exception, e.__struct__}}
  catch
    :exit, _ -> {:error, :exit}
  end

  @sql_recheck_legacy_token """
  SELECT 1 FROM matrix_sessions
   WHERE access_token_hash = $1 AND auth_api = 'legacy' AND user_id = $2 AND device_id = $3
  """

  # A bound raw JWT still owns the device: its binding row exists, the devices row exists and no OAuth
  # row holds the device (an OAuth take-over deletes the bindings only AFTER its commit, best effort).
  @sql_recheck_jwt_binding """
  SELECT 1 FROM jwt_device_bindings b
   WHERE b.token_hash = $1 AND b.user_id = $2 AND b.device_id = $3
     AND EXISTS (SELECT 1 FROM devices d WHERE d.user_id = $2 AND d.device_id = $3)
     AND NOT EXISTS (SELECT 1 FROM matrix_sessions m
                      WHERE m.user_id = $2 AND m.device_id = $3 AND m.auth_api = 'oauth')
  """

  @doc """
  The ONE transaction of the legacy `POST /logout` (bugfix legacy-logout-per-device, LL2/LL3/LL6): ends
  the device the presented LEGACY credential is bound to, with the SAME locked teardown as
  `end_session_for_token/1` and `end_device/3`:

    1. `SELECT 1 FROM devices ... FOR UPDATE` (the lock issuance, rotation incl. the legacy one, and every
       teardown take; lock order devices -> matrix_sessions);
    2. re-check AFTER the lock that the credential still belongs to `(user_id, device_id)`: `:opaque`: a
       `matrix_sessions` row of `auth_api = 'legacy'` with this access-token hash (any state); `:jwt`: the
       binding row exists, the `devices` row exists and the device holds NO OAuth row. A miss (an OAuth
       take-over or a concurrent teardown won) deletes NOTHING: `{:ok, :unknown}`;
    3. every `matrix_sessions` row of the device (a new statement: it sees a rotation that committed while
       we waited), then the device tables.

  `kind` is `:opaque` or `:jwt`; `token` is the plaintext credential (hashed HERE, once: the pass-the-hash
  rule). An opaque credential with an EMPTY `device_id` deletes only its own row (by hash) and no device.
  `{:ok, :ended} | {:ok, :unknown} | {:error, reason}` (rolled back); never raises.
  """
  @spec end_legacy_device(:opaque | :jwt, String.t(), String.t(), String.t(), module()) ::
          {:ok, :ended} | {:ok, :unknown} | {:error, term()}
  def end_legacy_device(kind, token, user_id, device_id, repo \\ repo())
      when kind in [:opaque, :jwt] and is_binary(token) and is_binary(user_id) and is_binary(device_id) do
    h = MatrixSessionStore.hash_token(token)

    txn =
      repo.transaction(fn ->
        cond do
          kind == :opaque and device_id == "" ->
            {:ok, %{num_rows: n}} =
              query!(repo, "DELETE FROM matrix_sessions WHERE access_token_hash = $1 AND auth_api = 'legacy' AND user_id = $2 AND device_id = ''", [h, user_id])

            if n > 0, do: :ended, else: :unknown

          device_id == "" ->
            :unknown

          true ->
            lock_device_bounded!(repo, user_id, device_id)

            {sql, params} =
              case kind do
                :opaque -> {@sql_recheck_legacy_token, [h, user_id, device_id]}
                :jwt -> {@sql_recheck_jwt_binding, [h, user_id, device_id]}
              end

            case query!(repo, sql, params) do
              {:ok, %{rows: []}} ->
                :unknown

              {:ok, _} ->
                delete_device_rows!(repo, user_id, device_id)
                :ended
            end
        end
      end)

    case txn do
      {:ok, outcome} -> {:ok, outcome}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _e in DeadlockError -> {:error, :deadlock}
    e -> if deadlock?(e), do: {:error, :deadlock}, else: {:error, {:exception, e.__struct__}}
  catch
    :exit, _ -> {:error, :exit}
  end

  @doc """
  Tears down EVERY device that has a `matrix_sessions` row of `client_id` (any state, any `auth_api`) INSIDE the
  caller's transaction (story oauth-client-revocation, CR4 step 2): the DISTINCT `(user_id, device_id)` pairs
  (ordered), then per pair the locked `end_device/3` teardown (devices row `FOR UPDATE`, all rows of the device,
  the device tables; the nested transaction joins the outer one), then a count that must be 0 (a session created
  meanwhile would mean the CR5 lock failed: `{:error, :race}`).

  `repo` MUST be the repo of the outer transaction and the store's own repo (a nested transaction joins only
  the same repo module): otherwise `{:error, :repo_mismatch}`. `{:ok, [{user_id, device_id}]}` or `{:error, reason}`
  (the caller MUST roll its transaction back). Never raises.
  """
  @spec end_client_devices(String.t(), module()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def end_client_devices(client_id, repo) when is_binary(client_id) do
    if repo != repo() do
      {:error, :repo_mismatch}
    else
      with {:ok, %{rows: rows}} <-
             query(repo, "SELECT DISTINCT user_id, device_id FROM matrix_sessions WHERE client_id = $1 ORDER BY 1, 2", [client_id]),
           pairs = Enum.map(rows, fn [u, d] -> {u, d} end),
           :ok <- end_each(pairs, repo),
           {:ok, %{rows: [[remaining]]}} <- query(repo, "SELECT count(*) FROM matrix_sessions WHERE client_id = $1", [client_id]) do
        if remaining == 0, do: {:ok, pairs}, else: {:error, :race}
      end
    end
  rescue
    e -> {:error, {:exception, e.__struct__}}
  catch
    :exit, _ -> {:error, :exit}
  end

  defp deadlock?(%Postgrex.Error{postgres: %{code: :deadlock_detected}}), do: true
  defp deadlock?(_), do: false

  defp end_each(pairs, repo) do
    Enum.reduce_while(pairs, :ok, fn {user_id, device_id}, :ok ->
      case end_device(user_id, device_id, repo, bounded?: false) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Live OAuth sessions per client for the admin list (story oauth-client-revocation, CR7): the number of DEVICES
  of each of `client_ids` with a `matrix_sessions` row whose `session_expires_at > now()`, in ONE query.
  `{:ok, %{client_id => count}}` (clients without one are absent) or `{:error, reason}`: the caller shows `?`,
  never `0`. At most 500 ids. Read only; never raises.
  """
  @spec client_session_counts([String.t()]) :: {:ok, %{String.t() => non_neg_integer()}} | {:error, term()}
  def client_session_counts([]), do: {:ok, %{}}

  def client_session_counts(client_ids) when is_list(client_ids) do
    ids = client_ids |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.take(500)

    sql = """
    SELECT client_id, count(DISTINCT (user_id, device_id))
      FROM matrix_sessions
     WHERE client_id = ANY($1) AND session_expires_at > now()
     GROUP BY client_id
    """

    case query(sql, [ids]) do
      {:ok, %{rows: rows}} -> {:ok, Map.new(rows, fn [id, n] -> {id, n} end)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Every DISTINCT `(user_id, device_id)` that has an `auth_api = 'oauth'` row, ordered, at most `limit`
  after the exclusive cursor `after_pair` (`nil` = from the start): the batches of the operator's "revoke all
  OAuth sessions" (story oauth-client-revocation, CR10). `{:ok, [{user_id, device_id}]}` or `{:error, reason}`.
  """
  @spec oauth_device_pairs({String.t(), String.t()} | nil, pos_integer()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def oauth_device_pairs(after_pair, limit) when is_integer(limit) and limit > 0 do
    {sql, params} =
      case after_pair do
        nil ->
          {"SELECT DISTINCT user_id, device_id FROM matrix_sessions WHERE auth_api = 'oauth' ORDER BY 1, 2 LIMIT $1", [limit]}

        {u, d} ->
          {"""
           SELECT DISTINCT user_id, device_id FROM matrix_sessions
            WHERE auth_api = 'oauth' AND (user_id, device_id) > ($2, $3)
            ORDER BY 1, 2 LIMIT $1
           """, [limit, u, d]}
      end

    case query(sql, params) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [u, d] -> {u, d} end)}
      {:error, _} = error -> error
    end
  end

  @doc "The DISTINCT device ids of the user that have an `auth_api = 'oauth'` row. `{:ok, [device_id]} | {:error, reason}`."
  @spec oauth_device_ids(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def oauth_device_ids(user_id) when is_binary(user_id) do
    case query("SELECT DISTINCT device_id FROM matrix_sessions WHERE user_id = $1 AND auth_api = 'oauth'", [user_id]) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [d] -> d end)}
      {:error, _} = error -> error
    end
  end

  @doc """
  The `auth_api` and `client_id` of the NEWEST LIVE session row (`revoked_at IS NULL`, any `auth_api`) of
  every device of `user_id`, for the account page's device list (story oauth-account-management, A12):
  `{:ok, %{device_id => %{auth_api: "legacy" | "oauth", client_id: String.t() | nil}}}` (a device without a
  live row is absent) or `{:error, reason}`. Read only; never raises.
  """
  @spec device_sessions(String.t()) :: {:ok, %{String.t() => %{auth_api: String.t(), client_id: String.t() | nil}}} | {:error, term()}
  def device_sessions(user_id) when is_binary(user_id) do
    sql = """
    SELECT DISTINCT ON (device_id) device_id, auth_api, client_id
      FROM matrix_sessions
     WHERE user_id = $1 AND revoked_at IS NULL
     ORDER BY device_id, created_at DESC
    """

    case query(sql, [user_id]) do
      {:ok, %{rows: rows}} -> {:ok, Map.new(rows, fn [device_id, auth_api, client_id] -> {device_id, %{auth_api: auth_api, client_id: client_id}} end)}
      {:error, _} = error -> error
    end
  end

  @doc """
  The `auth_api` and `client_id` of the NEWEST LIVE session row (`revoked_at IS NULL`, any `auth_api`) of ONE
  device (story oauth-authorize-freshness, FR11): `{:ok, %{auth_api:, client_id:}}`, `{:ok, nil}` when the
  device has no live row, or `{:error, reason}`. Read only; never raises.
  """
  @spec device_session(String.t(), String.t()) ::
          {:ok, %{auth_api: String.t(), client_id: String.t() | nil} | nil} | {:error, term()}
  def device_session(user_id, device_id) when is_binary(user_id) and is_binary(device_id) do
    sql = """
    SELECT auth_api, client_id FROM matrix_sessions
     WHERE user_id = $1 AND device_id = $2 AND revoked_at IS NULL
     ORDER BY created_at DESC
     LIMIT 1
    """

    case query(sql, [user_id, device_id]) do
      {:ok, %{rows: [[auth_api, client_id]]}} -> {:ok, %{auth_api: auth_api, client_id: client_id}}
      {:ok, %{rows: []}} -> {:ok, nil}
      {:error, _} = error -> error
    end
  end

  # ── IdP refresh lease (story oauth-authorize-freshness, FR15, gate n) ───────────────────

  @sql_claim_lease """
  INSERT INTO oauth_idp_refresh_leases (user_id, device_id, holder, acquired_at, lease_until)
  VALUES ($1, $2, $3, now(), now() + ($4::int * interval '1 second'))
  ON CONFLICT (user_id, device_id) DO UPDATE
    SET holder = EXCLUDED.holder, acquired_at = EXCLUDED.acquired_at, lease_until = EXCLUDED.lease_until
    WHERE oauth_idp_refresh_leases.lease_until <= now()
  RETURNING holder
  """

  @lease_lock_timeout "300ms"

  @doc """
  Claims the IdP refresh lease of `(user_id, device_id)` for `holder` for `ttl_seconds` (at most 120, a
  CHECK of the table): ONE statement, `INSERT ... ON CONFLICT DO UPDATE ... WHERE lease_until <=
  now() RETURNING holder`, in a short transaction under `SET LOCAL lock_timeout = '2s'` (the FK check waits
  for a revoke holding the `devices` row; G3-1). Only a FREE or EXPIRED lease can be taken; a live one is never
  taken over.

  `:claimed`, `:busy` (a live lease of another holder exists), `:no_device` (the device row is gone: nothing
  to serialize, the caller proceeds without a lease), `{:error, :lock_timeout}` (the devices row is locked
  longer than 300 ms: the caller answers 503 + Retry-After) or `{:error, reason}`. Never raises.
  """
  @spec claim_lease(String.t(), String.t(), String.t(), pos_integer()) ::
          :claimed | :busy | :no_device | {:error, :lock_timeout} | {:error, term()}
  def claim_lease(user_id, device_id, holder, ttl_seconds)
      when is_binary(user_id) and is_binary(device_id) and is_binary(holder) and is_integer(ttl_seconds) do
    repo = repo()

    # A SHORT transaction (no IdP call inside, nothing held afterwards) only to scope `SET LOCAL lock_timeout` (300 ms: an
    # uncontended claim takes milliseconds, so a short bound keeps the pool connection hold of a waiter small, Kassandra L-1):
    # the INSERT's FK check takes KEY SHARE on the `devices` row and therefore waits for a long
    # `Nebu.OAuth.revoke_client/3` (G3-1, story revoke-lock-bounds). The wait is bounded like `lock_client!/2`; a
    # timeout rolls the transaction back (no lease row) and is its own outcome, `{:error, :lock_timeout}`.
    txn =
      repo.transaction(fn ->
        query!(repo, "SET LOCAL lock_timeout = '#{@lease_lock_timeout}'", [])

        outcome =
          case Ecto.Adapters.SQL.query(repo, @sql_claim_lease, [user_id, device_id, holder, ttl_seconds]) do
            {:ok, %{rows: [[^holder]]}} -> :claimed
            {:ok, %{rows: []}} -> :busy
            {:error, %Postgrex.Error{postgres: %{code: :foreign_key_violation}}} -> :no_device
            {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} -> repo.rollback(:lock_timeout)
            {:error, %Postgrex.Error{postgres: %{code: :deadlock_detected}}} -> raise DeadlockError
            {:error, _} -> repo.rollback(:query_failed)
            _other -> repo.rollback(:unexpected_result)
          end

        # a failed FK check aborts the transaction: there is nothing to reset, the rollback below ends it
        if outcome == :no_device, do: repo.rollback(:no_device)
        query!(repo, "SET LOCAL lock_timeout = DEFAULT", [])
        outcome
      end)

    case txn do
      {:ok, outcome} -> outcome
      {:error, :no_device} -> :no_device
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:exception, e.__struct__}}
  catch
    :exit, _ -> {:error, :exit}
  end

  @doc """
  Releases the lease of `(user_id, device_id)` held by `holder` (a `DELETE ... WHERE holder = $3`: never someone
  else's). `:ok | {:error, reason}`. The DELETE of a lease row waits for a revoke that cascade-deleted it (the
  teardown deletes the `devices` row), so it runs under the same 300 ms `SET LOCAL lock_timeout` as the claim (it can add at most that bound to a refresh response)
  (`{:error, :lock_timeout}`: the caller logs, the lease row goes with the device or expires by itself).
  """
  @spec release_lease(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def release_lease(user_id, device_id, holder) when is_binary(user_id) and is_binary(device_id) and is_binary(holder) do
    repo = repo()

    txn =
      repo.transaction(fn ->
        query!(repo, "SET LOCAL lock_timeout = '#{@lease_lock_timeout}'", [])

        case Ecto.Adapters.SQL.query(
               repo,
               "DELETE FROM oauth_idp_refresh_leases WHERE user_id = $1 AND device_id = $2 AND holder = $3",
               [user_id, device_id, holder]
             ) do
          {:ok, _} -> :ok
          {:error, %Postgrex.Error{postgres: %{code: :lock_not_available}}} -> repo.rollback(:lock_timeout)
          {:error, _} -> repo.rollback(:query_failed)
        end
      end)

    case txn do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, {:exception, e.__struct__}}
  catch
    :exit, _ -> {:error, :exit}
  end

  # The devices-row lock (same lock as issuance and rotation). When there is NO devices row (a legacy login ignores a
  # failed `register_device`, so a device-less session row can exist) the device cannot be locked, so the device's
  # `matrix_sessions` rows are locked instead (`ORDER BY` the key: one lock order for concurrent teardowns), and the
  # DELETE that follows (a new statement, a new snapshot) also sees a rotation that committed while we waited
  # (Kassandra L1, bugfix legacy-logout-per-device).
  defp lock_device(repo, user_id, device_id) do
    case query!(repo, "SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [user_id, device_id]) do
      {:ok, %{num_rows: 0}} -> lock_session_rows(repo, user_id, device_id)
      {:ok, _} -> :ok
    end
  end

  defp lock_session_rows(repo, user_id, device_id) do
    query!(
      repo,
      "SELECT 1 FROM matrix_sessions WHERE user_id = $1 AND device_id = $2 ORDER BY access_token_hash FOR UPDATE",
      [user_id, device_id]
    )

    :ok
  end

  # The legacy `/logout` waits for the lock at most 2 s (`SET LOCAL lock_timeout`, reset right after), like
  # `lock_client!/2`: a request must not hold a pool connection behind a long same-user transaction. A timeout rolls
  # back as `:lock_timeout` (the facade answers `{:error, :unavailable}`, `500`; the client may retry).
  @device_lock_timeout "2s"

  defp lock_device_bounded!(repo, user_id, device_id, timeout \\ @device_lock_timeout) do
    query!(repo, "SET LOCAL lock_timeout = '#{timeout}'", [])

    result =
      case Ecto.Adapters.SQL.query(repo, "SELECT 1 FROM devices WHERE user_id = $1 AND device_id = $2 FOR UPDATE", [user_id, device_id]) do
        {:ok, %{num_rows: 0}} -> bounded_session_rows(repo, user_id, device_id)
        {:ok, _} -> :ok
        {:error, error} -> lock_error(error)
      end

    if result == :lock_timeout, do: repo.rollback(:lock_timeout)
    query!(repo, "SET LOCAL lock_timeout = DEFAULT", [])
    :ok
  end

  defp bounded_session_rows(repo, user_id, device_id) do
    sql = "SELECT 1 FROM matrix_sessions WHERE user_id = $1 AND device_id = $2 ORDER BY access_token_hash FOR UPDATE"

    case Ecto.Adapters.SQL.query(repo, sql, [user_id, device_id]) do
      {:ok, _} -> :ok
      {:error, error} -> lock_error(error)
    end
  end

  defp lock_error(%Postgrex.Error{postgres: %{code: :lock_not_available}}), do: :lock_timeout
  defp lock_error(%Postgrex.Error{postgres: %{code: :deadlock_detected}}), do: raise(DeadlockError)
  defp lock_error(_), do: raise(DBConnection.ConnectionError, "oauth session store query failed")

  defp delete_device_rows!(repo, user_id, device_id) do
    {:ok, _} = query!(repo, "DELETE FROM matrix_sessions WHERE user_id = $1 AND device_id = $2", [user_id, device_id])
    :ok = Nebu.Matrix.DeviceKeyStore.delete_device!(user_id, device_id, repo)
  end

  @doc "Deletes every `auth_api = 'oauth'` row of `(user_id, device_id)` (T11 reuse / IdP rejection / T26 take-over). `:ok | {:error, term}`."
  @spec delete_device_oauth(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_device_oauth(user_id, device_id) when is_binary(user_id) and is_binary(device_id) do
    case query("DELETE FROM matrix_sessions WHERE user_id = $1 AND device_id = $2 AND auth_api = 'oauth'", [user_id, device_id]) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  T8: deletes every `auth_api = 'oauth'` row of the device(s) whose rows carry `oauth_code_hash =
  code_hash` (the session derived from that code, also after rotations). Returns the derived
  `[{user_id, device_id}]` (for logging) or `{:error, term}`.
  """
  @spec delete_by_code_hash(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def delete_by_code_hash(code_hash) when is_binary(code_hash) do
    sql = """
    DELETE FROM matrix_sessions
     WHERE auth_api = 'oauth'
       AND (user_id, device_id) IN (SELECT user_id, device_id FROM matrix_sessions
                                     WHERE oauth_code_hash = $1 AND auth_api = 'oauth')
    RETURNING user_id, device_id
    """

    case query(sql, [code_hash]) do
      {:ok, %{rows: rows}} -> {:ok, rows |> Enum.map(fn [u, d] -> {u, d} end) |> Enum.uniq()}
      {:error, _} = error -> error
    end
  end

  # ── internals ──────────────────────────────────────────────────────────────

  defp to_session([at_h, rt_h, enc, user_id, device_id, expires_at, revoked_at, grace_until, client_id, scope, sess_exp, auth_time, code_hash]) do
    %{
      access_token_hash: at_h,
      refresh_token_hash: rt_h,
      oidc_refresh_token: enc,
      user_id: user_id,
      device_id: device_id,
      expires_at: expires_at,
      revoked_at: revoked_at,
      grace_until: grace_until,
      client_id: client_id,
      scope: scope,
      session_expires_at: sess_exp,
      auth_time: auth_time,
      oauth_code_hash: code_hash
    }
  end

  # Test-only seam, compile-time guarded (Dev Notes "Test-only seams"): a stray application env in
  # a release can never replace the repository.
  if Mix.env() == :test do
    defp repo, do: Application.get_env(:nebu_http, :oauth_session_repo, Nebu.Repo)
  else
    defp repo, do: Nebu.Repo
  end

  # Inside a transaction: errors raise (rollback); the caller rescues. Bound parameters are never
  # logged (Nebu.Repo has `log: false`).
  defp query!(sql, params), do: query!(repo(), sql, params)

  defp query!(repo, sql, params) do
    case Ecto.Adapters.SQL.query(repo, sql, params) do
      {:ok, _} = ok -> ok
      {:error, %Postgrex.Error{postgres: %{code: :deadlock_detected}}} -> raise DeadlockError
      {:error, _} -> raise DBConnection.ConnectionError, "oauth session store query failed"
    end
  end

  defp query(sql, params), do: query(repo(), sql, params)

  defp query(repo, sql, params) do
    Ecto.Adapters.SQL.query(repo, sql, params)
  rescue
    e -> {:error, {:exception, e.__struct__}}
  catch
    :exit, _ -> {:error, :exit}
  end
end
