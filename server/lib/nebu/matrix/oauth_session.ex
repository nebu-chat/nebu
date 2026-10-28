defmodule Nebu.Matrix.OAuthSession do
  @moduledoc """
  Matrix side of the OAuth token endpoint (story oauth-token-endpoint, epic oauth-broker): session
  issuance and refresh orchestration for `auth_api = 'oauth'` rows of `matrix_sessions`. Reached
  from the OAuth domain ONLY through the `Nebu.Matrix` facade (`oauth_issue_session/1`,
  `oauth_resolve_refresh_token/1`, `oauth_refresh_session/4`, `oauth_revoke_device_session/2`,
  `oauth_revoke_sessions_for_code/1`, ADR-020). Persistence: `Nebu.Matrix.Session.OAuthSessionStore`.

    * `issue/1` (AC7, T7, T19): error-aware `is_active` read, then ONE transaction (device upsert,
      every earlier row of the device deleted, new OAuth row), then — best effort, after the
      commit — the S3 kill-switch for raw IdP JWTs bound to the reused device (denylist by hash,
      bindings deleted; the device and its E2EE keys are kept).
    * `refresh/4` (AC9, AC10, T5, T10, T11, T19, T28): IdP re-validation (`per_refresh`: the stored
      IdP refresh token through `HttpPublic.revalidate_with_idp/1`, classified by `RefreshErrors`;
      `off`: only `is_active`), then the rotation; a lost rotation race is re-resolved and retried
      (bounded, exhaustion => unavailable). T28: a CONFIRMED IdP rejection is final only when the
      device's active row is unchanged; when a concurrent refresh rotated it meanwhile the request
      is served as a replay without a second IdP call.

  ## IdP refresh lease (story oauth-authorize-freshness, FR15, gate n)

  A rotating IdP with reuse detection revokes the whole grant when one IdP refresh token is redeemed
  twice, so two parallel `per_refresh` refreshes of one device must never BOTH call the IdP. The IdP leg
  therefore runs under a per-device LEASE (a row of `oauth_idp_refresh_leases`, see
  `Nebu.Matrix.Session.OAuthSessionStore`; NOT an advisory lock, which would hold a pool connection and a
  transaction across the HTTP call). The holder re-validates the state, calls the IdP, rotates and
  releases (in `after`). A follower polls every #{100} ms for at most `@idp_lease_wait_ms` and re-resolves
  the refresh token each time: a CHANGED active row means the holder rotated, so it is served as a replay
  WITHOUT an IdP call; a consumed token (`{:reused, _}`) while waiting is `{:unavailable, 2}` (503), NEVER
  a revocation (the token endpoint's next request goes through T11); a free lease is claimed, after one
  more re-resolve; an exhausted budget is `{:unavailable, 2}`; a lease SQL error is `{:unavailable, 5}`; a lock timeout of the claim (300 ms; a long client revocation holds the
  devices row, G3-1) is `{:unavailable, 5}` (Kassandra L-1: a short retry would keep the pool busy).
  `idp_revalidation: :off` takes no lease. A killed holder leaves its lease until the TTL (60 s). T28 remains for an EXPIRED lease (a holder that stalled past
  its TTL).

  Revocation (story oauth-token-revocation-logout, R2/R11/R17): `revoke_token/1` ends the whole OAuth
  session of the device (every `matrix_sessions` row, the `devices` row with its E2EE keys) in one
  transaction under the shared devices-row lock, then the best-effort post-commit part (JWT
  kill-switch, per-device legacy session rows); `end_device_session/2`, `end_all_for_user/1` and
  `end_all_devices/1` serve `/logout/all` and the GDPR erasure. The legacy `POST /logout` (opaque token or raw
  IdP JWT bound to a device) uses the same locked teardown for ONLY the presented credential's device:
  `end_legacy_device/1` (bugfix legacy-logout-per-device, LL1-LL12; the credential is re-checked under the
  devices-row lock, so an OAuth take-over or a concurrent teardown deletes nothing).

  Never raises; errors are atoms / `{:unavailable, retry_after_s}`. Never logs a token, an IdP
  token, a scope value or key material (T29).

  Test seams (compiled in only for `MIX_ENV=test`): `:nebu_http, :oauth_user_active_override`
  (1-arity `user_id -> {:ok, boolean} | {:error, term}`) and `:nebu_http, :oauth_rotate_override`
  (1-arity, called INSTEAD of `OAuthSessionStore.rotate/1`).
  """

  require Logger

  alias Nebu.Matrix.Session.{MatrixSessionStore, OAuthSessionStore, RefreshErrors}

  # Max re-resolutions after a lost rotation race (same bound as the legacy /refresh).
  @race_retries 12
  @db_retry_after_s 5

  # FR15: the lease TTL covers the worst IdP leg of one refresh. Every `:httpc` call there is bounded by
  # `timeout: 5_000, connect_timeout: 5_000` (up to ~10 s each: connect, then the request) and the leg is
  # discovery + token endpoint + the JWKS fetch of the id_token verification (3 calls, ~30 s worst case) plus the
  # database round trips. 60 s covers that with margin (review cycle 1, M1/L-3); a CHECK of the table caps a
  # lease at 120 s. A holder that outlives it is the T28 case (no fencing token: follow-up). A holder that is
  # killed (node crash) leaves its lease until the TTL: followers get `503` + `Retry-After: 2` for at most 60 s,
  # never a revocation.
  @idp_lease_seconds 60
  # A follower waits at most this long for the holder (test seam `:oauth_idp_lease_wait_ms`), polling this often.
  @idp_lease_wait_ms 5_000
  @idp_lease_poll_ms 100
  # Retry-After of a follower that could not be served in time: the holder is about to finish.
  @contention_retry_after_s 2

  @type refresh_result ::
          {:ok, map()} | {:error, :invalid_grant} | {:error, {:unavailable, pos_integer()}}

  # ── is_active (T19) ──────────────────────────────────────────────────────────

  @doc "Error-aware `users.is_active` (T19): `{:ok, true | false}` (unknown user => false) or `{:error, reason}`."
  @spec user_active(String.t()) :: {:ok, boolean()} | {:error, term()}
  def user_active(user_id) when is_binary(user_id) do
    case seam(:oauth_user_active_override, nil) do
      fun when is_function(fun, 1) -> fun.(user_id)
      _ -> OAuthSessionStore.user_active(user_id)
    end
  rescue
    e -> {:error, {:exception, e.__struct__}}
  end

  # ── issuance (AC7) ───────────────────────────────────────────────────────────

  @doc "See `Nebu.Matrix.oauth_issue_session/1`."
  @spec issue(map()) :: {:ok, map()} | {:error, :inactive | :unavailable | :device_in_use | :client_not_approved}
  def issue(attrs) when is_map(attrs) do
    case user_active(attrs.user_id) do
      {:ok, true} -> do_issue(attrs)
      {:ok, false} -> {:error, :inactive}
      {:error, _} -> {:error, :unavailable}
    end
  end

  defp do_issue(attrs) do
    at = MatrixSessionStore.generate_opaque_token()
    rt = MatrixSessionStore.generate_opaque_token()

    store_attrs =
      Map.merge(attrs, %{
        access_token: at,
        refresh_token: rt,
        session_ttl_seconds: Nebu.Web.SessionConfig.matrix_session_ttl_seconds()
      })

    case OAuthSessionStore.insert_replacing_device(store_attrs) do
      {:ok, expires_in} ->
        kill_bound_jwts(attrs.user_id, attrs.device_id)

        Logger.info("oauth session created",
          user_id: attrs.user_id,
          device_id: attrs.device_id,
          client_id: attrs.client_id
        )

        {:ok,
         %{
           access_token: at,
           refresh_token: rt,
           expires_in: expires_in,
           user_id: attrs.user_id,
           device_id: attrs.device_id,
           scope: attrs.scope,
           auth_time: attrs.auth_time
         }}

      # L-1: the device is held by another app than the one the user accepted at consent
      {:error, :device_in_use} ->
        Logger.warning("oauth session issuance refused: the device holder changed since consent",
          user_id: attrs.user_id,
          device_id: attrs.device_id,
          client_id: attrs.client_id
        )

        {:error, :device_in_use}

      # story oauth-client-revocation CR5: the client was revoked between the token endpoint's lookup and the
      # issuance (the client row is locked FOR SHARE under the transaction); nothing was written
      {:error, :client_not_approved} ->
        Logger.warning("oauth session issuance refused: the client is no longer approved",
          client_id: attrs.client_id
        )

        {:error, :client_not_approved}

      {:error, reason} ->
        Logger.warning("oauth session issuance failed: #{describe(reason)}")
        {:error, :unavailable}
    end
  end

  # T7 / T25 (a): the S3 kill-switch for raw IdP JWTs bound to the (reused / ended) device — the single
  # shared `DeviceBinding.kill_device_jwts/3` (story oauth-legacy-coexistence C13 b): bindings are
  # deleted only after a CONFIRMED denylist write, kept (fail closed) otherwise. Best effort: never fails
  # the grant or the revocation.
  defp kill_bound_jwts(user_id, device_id) do
    _ = Nebu.Matrix.Session.DeviceBinding.kill_device_jwts(user_id, device_id)
    :ok
  end

  # ── refresh (AC9, AC10) ──────────────────────────────────────────────────────

  @doc "See `Nebu.Matrix.oauth_resolve_refresh_token/1`."
  @spec resolve_refresh_token(String.t()) ::
          {:ok, map(), :current | :replay} | {:reused, map()} | :error | {:error, :unavailable}
  def resolve_refresh_token(rt) when is_binary(rt) do
    OAuthSessionStore.resolve_refresh_token(rt)
  rescue
    _ -> {:error, :unavailable}
  end

  def resolve_refresh_token(_rt), do: :error

  @doc "See `Nebu.Matrix.oauth_refresh_session/4`."
  @spec refresh(map(), :current | :replay, String.t(), map()) :: refresh_result()
  def refresh(session, mode, rt, opts) when mode in [:current, :replay] and is_binary(rt) and is_map(opts) do
    case Map.get(opts, :idp_revalidation, :per_refresh) do
      :off -> refresh_unleased(session, mode, rt, opts)
      _per_refresh -> refresh_leased(session, mode, rt, opts)
    end
  rescue
    e ->
      Logger.warning("oauth session refresh: unexpected #{inspect(e.__struct__)}, session left intact")
      {:error, {:unavailable, @db_retry_after_s}}
  end

  # The re-validation + rotation of `refresh/4` (no lease).
  defp refresh_unleased(session, mode, rt, opts) do
    case revalidate(session, Map.get(opts, :idp_revalidation, :per_refresh)) do
      {:ok, new_idp_rt_enc} ->
        rotate_loop(session, mode, rt, opts, new_idp_rt_enc, @race_retries)

      {:error, {:unavailable, _} = unavailable} ->
        {:error, unavailable}

      {:error, :confirmed, reason} ->
        confirmed_rejection(session, rt, opts, reason)
    end
  end

  # ── the per-device IdP refresh lease (FR15) ──────────────────────────────────

  defp refresh_leased(session, mode, rt, opts) do
    holder = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    deadline = System.monotonic_time(:millisecond) + seam(:oauth_idp_lease_wait_ms, @idp_lease_wait_ms)
    acquire_lease(session, mode, rt, opts, holder, deadline, true)
  end

  defp acquire_lease(session, mode, rt, opts, holder, deadline, first_attempt?) do
    case OAuthSessionStore.claim_lease(session.user_id, session.device_id, holder, @idp_lease_seconds) do
      :claimed ->
        run_as_holder(session, mode, rt, opts, holder)

      # the device row is gone: nothing to serialize with, behave as before the lease existed
      :no_device ->
        refresh_unleased(session, mode, rt, opts)

      :busy ->
        if first_attempt?, do: notify_wait()
        wait_for_lease(session, mode, rt, opts, holder, deadline)

      # a long client revocation holds the devices row (G3-1): the claim's 300 ms lock bound ran out, the client retries later
      {:error, :lock_timeout} ->
        Logger.warning("oauth session refresh: IdP refresh lease claim timed out on a locked device row, session left intact",
          user_id: session.user_id,
          device_id: session.device_id
        )

        {:error, {:unavailable, @db_retry_after_s}}

      {:error, _reason} ->
        Logger.warning("oauth session refresh: IdP refresh lease unavailable, session left intact",
          user_id: session.user_id,
          device_id: session.device_id
        )

        {:error, {:unavailable, @db_retry_after_s}}
    end
  end

  # The holder: AFTER the claim the state is re-validated (the previous holder may have finished between our
  # resolve and our claim: calling the IdP then would redeem the rotated-away IdP token a second time). The
  # lease is released in `after` on EVERY path (a raising IdP call included).
  defp run_as_holder(session, mode, rt, opts, holder) do
    try do
      case OAuthSessionStore.resolve_refresh_token(rt) do
        {:ok, active, new_mode} ->
          if active.access_token_hash == session.access_token_hash do
            refresh_unleased(session, mode, rt, opts)
          else
            # rotated meanwhile by the previous holder: a replay, NO IdP call
            rotate_loop(active, new_mode, rt, opts, nil, @race_retries)
          end

        {:reused, _consumed} ->
          {:error, {:unavailable, @contention_retry_after_s}}

        {:error, :unavailable} ->
          {:error, {:unavailable, @db_retry_after_s}}

        :error ->
          {:error, :invalid_grant}
      end
    after
      release_lease(session, holder)
    end
  end

  defp wait_for_lease(session, mode, rt, opts, holder, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Logger.info("oauth session refresh: IdP refresh lease still held, asking the client to retry",
        user_id: session.user_id,
        device_id: session.device_id
      )

      {:error, {:unavailable, @contention_retry_after_s}}
    else
      Process.sleep(min(@idp_lease_poll_ms, remaining))

      case OAuthSessionStore.resolve_refresh_token(rt) do
        {:ok, active, new_mode} ->
          if active.access_token_hash == session.access_token_hash do
            acquire_lease(session, mode, rt, opts, holder, deadline, false)
          else
            # the holder rotated: serve this request as a replay, WITHOUT an IdP call
            rotate_loop(active, new_mode, rt, opts, nil, @race_retries)
          end

        # a consumed token while waiting (a third refresh used the successor): never a revocation
        {:reused, _consumed} ->
          {:error, {:unavailable, @contention_retry_after_s}}

        {:error, :unavailable} ->
          {:error, {:unavailable, @db_retry_after_s}}

        :error ->
          {:error, :invalid_grant}
      end
    end
  end

  defp release_lease(session, holder) do
    case OAuthSessionStore.release_lease(session.user_id, session.device_id, holder) do
      :ok ->
        :ok

      {:error, _reason} ->
        # the lease expires by itself (TTL); nothing else to do
        Logger.warning("oauth session refresh: IdP refresh lease could not be released (it expires by itself)",
          user_id: session.user_id,
          device_id: session.device_id
        )
    end
  end

  # `{:ok, new_idp_rt_enc | nil}` | `{:error, {:unavailable, s}}` | `{:error, :confirmed, reason}`
  defp revalidate(session, :off) do
    case user_active(session.user_id) do
      {:ok, true} -> {:ok, nil}
      {:ok, false} -> {:error, :confirmed, :deactivated}
      {:error, _} -> {:error, {:unavailable, @db_retry_after_s}}
    end
  end

  defp revalidate(session, _per_refresh) do
    case Nebu.Matrix.HttpPublic.revalidate_with_idp(session) do
      {:ok, _claims, nil} ->
        {:ok, nil}

      {:ok, _claims, new_rt} when is_binary(new_rt) ->
        case encrypt(new_rt) do
          {:ok, enc} -> {:ok, enc}
          :error -> {:error, {:unavailable, @db_retry_after_s}}
        end

      {:ok, _claims, _other} ->
        {:ok, nil}

      {:error, reason} ->
        if RefreshErrors.transient?(reason) do
          Logger.warning("oauth session refresh: transient IdP re-validation failure, session left intact",
            user_id: session.user_id,
            device_id: session.device_id,
            reason: RefreshErrors.describe(reason)
          )

          {:error, {:unavailable, RefreshErrors.retry_after_seconds(reason)}}
        else
          {:error, :confirmed, reason}
        end
    end
  end

  defp encrypt(plain) do
    {:ok, Nebu.Web.SecretBox.encrypt(plain)}
  rescue
    _ -> :error
  end

  # T28 (review cycle 1, Kassandra F-1): a rotating IdP rejects the loser of two concurrent
  # redemptions of the same IdP refresh token with a 400. That rejection is NOT final only when ALL of:
  #   * it is a genuine IdP token-endpoint rejection (`{:token_endpoint_status, 400 | 401}` /
  #     `:invalid_grant`) — never a Nebu-side verdict (`:deactivated`, `:no_oidc_refresh_token`,
  #     decrypt failures), which always revoke, and
  #   * the device's active row now carries a NEW IdP refresh-token ciphertext, i.e. a concurrent
  #     refresh really redeemed the IdP token and stored the provider-rotated successor.
  # A row that merely has a new access-token hash proves nothing (a "skip" itself rewrites the hash and
  # would let a token holder bypass `per_refresh` with overlapping refreshes): the rejection is final.
  defp confirmed_rejection(session, rt, opts, reason) do
    if genuine_idp_rejection?(reason) do
      case OAuthSessionStore.active_row(session.user_id, session.device_id) do
        {:ok, %{oidc_refresh_token: enc}} when enc != session.oidc_refresh_token ->
          lost_race_replay(rt, opts)

        {:error, :unavailable} ->
          {:error, {:unavailable, @db_retry_after_s}}

        _unchanged_or_none ->
          reject_and_revoke(session, reason)
      end
    else
      reject_and_revoke(session, reason)
    end
  end

  defp genuine_idp_rejection?({:token_endpoint_status, status}) when status in [400, 401], do: true
  defp genuine_idp_rejection?(:invalid_grant), do: true
  defp genuine_idp_rejection?(_reason), do: false

  # The concurrent winner re-validated milliseconds ago: serve this request as a replay of the
  # (now pending) token WITHOUT a second IdP call.
  defp lost_race_replay(rt, opts) do
    case OAuthSessionStore.resolve_refresh_token(rt) do
      {:ok, active, new_mode} -> rotate_loop(active, new_mode, rt, opts, nil, @race_retries)
      {:reused, reused} -> reuse_revoke(reused)
      {:error, :unavailable} -> {:error, {:unavailable, @db_retry_after_s}}
      :error -> {:error, :invalid_grant}
    end
  end

  defp reject_and_revoke(session, reason) do
    Logger.warning("oauth session refresh: re-validation rejected, session revoked",
      user_id: session.user_id,
      device_id: session.device_id,
      client_id: session.client_id,
      reason: RefreshErrors.describe(reason)
    )

    revoke_device(session.user_id, session.device_id)
  end

  defp rotate_loop(session, mode, rt, opts, new_idp_rt_enc, retries_left) do
    at = MatrixSessionStore.generate_opaque_token()
    new_rt = MatrixSessionStore.generate_opaque_token()

    params =
      %{
        active_access_token_hash: session.access_token_hash,
        new_access_token: at,
        new_refresh_token: new_rt,
        access_ttl_seconds: Map.get(opts, :access_ttl_seconds, 900),
        scope: Map.get(opts, :scope) || session.scope,
        new_oidc_refresh_token: new_idp_rt_enc,
        consume_pending_siblings: mode == :current
      }
      |> then(fn p -> if mode == :replay, do: Map.put(p, :replay_refresh_token, rt), else: p end)

    case safe_rotate(params) do
      {:ok, expires_in} ->
        Logger.info("oauth session refreshed",
          user_id: session.user_id,
          device_id: session.device_id,
          client_id: session.client_id
        )

        {:ok,
         %{
           access_token: at,
           refresh_token: new_rt,
           expires_in: expires_in,
           scope: params.scope,
           user_id: session.user_id,
           device_id: session.device_id,
           auth_time: session.auth_time
         }}

      {:error, :consumed} ->
        reuse_revoke(session)

      # story oauth-client-revocation CR5: the client was revoked meanwhile; its sessions are gone (or about to be)
      {:error, :client_not_approved} ->
        {:error, :invalid_grant}

      :unavailable ->
        {:error, {:unavailable, @db_retry_after_s}}

      :error when retries_left > 0 ->
        # Lost a rotation race (exactly one winner per row): re-resolve, no second IdP call (the
        # winner re-validated a moment ago).
        case OAuthSessionStore.resolve_refresh_token(rt) do
          {:ok, active, new_mode} -> rotate_loop(active, new_mode, rt, opts, new_idp_rt_enc, retries_left - 1)
          {:reused, reused} -> reuse_revoke(reused)
          {:error, :unavailable} -> {:error, {:unavailable, @db_retry_after_s}}
          :error -> {:error, :invalid_grant}
        end

      :error ->
        Logger.warning("oauth session refresh: rotation race retries exhausted, session left intact",
          user_id: session.user_id,
          device_id: session.device_id
        )

        {:error, {:unavailable, @db_retry_after_s}}
    end
  end

  defp safe_rotate(params) do
    result =
      case seam(:oauth_rotate_override, nil) do
        fun when is_function(fun, 1) -> fun.(params)
        _ -> OAuthSessionStore.rotate(params)
      end

    case result do
      {:ok, n} when is_integer(n) -> {:ok, n}
      :ok -> {:ok, Map.get(params, :access_ttl_seconds, 900)}
      :error -> :error
      {:error, :consumed} -> {:error, :consumed}
      {:error, :client_not_approved} -> {:error, :client_not_approved}
      _ -> :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  # T11: a consumed refresh token while the session is alive => the whole OAuth session of the device.
  defp reuse_revoke(session) do
    Logger.warning("oauth session refresh: consumed refresh token reused, session revoked",
      user_id: session.user_id,
      device_id: session.device_id,
      client_id: session.client_id
    )

    revoke_device(session.user_id, session.device_id)
  end

  defp revoke_device(user_id, device_id) do
    case OAuthSessionStore.delete_device_oauth(user_id, device_id) do
      :ok -> {:error, :invalid_grant}
      {:error, _} -> {:error, {:unavailable, @db_retry_after_s}}
    end
  end

  # ── revocation helpers (facade) ──────────────────────────────────────────────

  @doc "See `Nebu.Matrix.oauth_revoke_device_session/2`."
  @spec revoke_device_session(String.t(), String.t()) :: :ok | {:error, :unavailable}
  def revoke_device_session(user_id, device_id) do
    case OAuthSessionStore.delete_device_oauth(user_id, device_id) do
      :ok -> :ok
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc "See `Nebu.Matrix.oauth_revoke_sessions_for_code/1`."
  @spec revoke_sessions_for_code(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, :unavailable}
  def revoke_sessions_for_code(code_hash) when is_binary(code_hash) do
    case OAuthSessionStore.delete_by_code_hash(code_hash) do
      {:ok, devices} -> {:ok, devices}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  # ── revocation / logout (story oauth-token-revocation-logout, R2, R11, R17, R24) ───────────

  @doc "See `Nebu.Matrix.oauth_revoke_token/1`."
  @spec revoke_token(term()) ::
          {:ok, :revoked, %{user_id: String.t(), device_id: String.t(), client_id: String.t()}}
          | {:ok, :unknown}
          | {:error, :unavailable}
  def revoke_token(token) when is_binary(token) do
    # Defence in depth (R24): a value that is not a Nebu opaque token (64 lowercase hex) is unknown
    # WITHOUT any database access.
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, token) do
      case OAuthSessionStore.end_session_for_token(token) do
        {:ok, :revoked, %{user_id: user_id, device_id: device_id} = info} ->
          after_commit(user_id, device_id)
          {:ok, :revoked, info}

        {:ok, :unknown} ->
          {:ok, :unknown}

        {:error, reason} ->
          Logger.warning("oauth revoke: storage failure (#{describe(reason)})")
          {:error, :unavailable}
      end
    else
      {:ok, :unknown}
    end
  rescue
    e ->
      Logger.warning("oauth revoke: unexpected #{inspect(e.__struct__)}")
      {:error, :unavailable}
  catch
    :exit, _ ->
      Logger.warning("oauth revoke: unexpected exit")
      {:error, :unavailable}
  end

  def revoke_token(_token), do: {:ok, :unknown}

  @doc "Ends the OAuth session + device of `(user_id, device_id)` (R2) incl. the post-commit part. `:ok | {:error, :unavailable}`."
  @spec end_device_session(String.t(), String.t()) :: :ok | {:error, :unavailable}
  def end_device_session(user_id, device_id) when is_binary(user_id) and is_binary(device_id) do
    case OAuthSessionStore.end_device(user_id, device_id) do
      :ok ->
        after_commit(user_id, device_id)
        :ok

      {:error, reason} ->
        Logger.warning("oauth session end: storage failure (#{describe(reason)})", device_id: device_id)
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  See `Nebu.Matrix.legacy_logout_device/1` (bugfix legacy-logout-per-device, LL2/LL3/LL10): the locked
  teardown of the device the presented LEGACY credential is bound to (`OAuthSessionStore.end_legacy_device/5`),
  then, only when something was ended and the device id is not empty, the post-commit part (JWT kill-switch of
  the device, per-device legacy `sessions` / `sync_tokens`). Never logs a token.
  """
  @spec end_legacy_device(map()) :: {:ok, :ended} | {:ok, :unknown} | {:error, :unavailable}
  def end_legacy_device(%{kind: kind, token: token, user_id: user_id, device_id: device_id})
      when kind in [:opaque, :jwt] and is_binary(token) and is_binary(user_id) and is_binary(device_id) do
    case OAuthSessionStore.end_legacy_device(kind, token, user_id, device_id) do
      {:ok, :ended} ->
        if device_id != "", do: after_commit(user_id, device_id)
        {:ok, :ended}

      {:ok, :unknown} ->
        {:ok, :unknown}

      {:error, reason} ->
        Logger.warning("legacy logout: storage failure (#{describe(reason)})")
        {:error, :unavailable}
    end
  rescue
    e ->
      Logger.warning("legacy logout: unexpected #{inspect(e.__struct__)}")
      {:error, :unavailable}
  catch
    :exit, _ ->
      Logger.warning("legacy logout: unexpected exit")
      {:error, :unavailable}
  end

  def end_legacy_device(_), do: {:error, :unavailable}

  @doc "See `Nebu.Matrix.oauth_end_user_sessions/1`: every device with an OAuth row, the first failure wins, the rest is still attempted."
  @spec end_all_for_user(String.t()) :: {:ok, [String.t()]} | {:error, :unavailable}
  def end_all_for_user(user_id) when is_binary(user_id) do
    case OAuthSessionStore.oauth_device_ids(user_id) do
      {:ok, device_ids} ->
        results = Enum.map(device_ids, &end_device_session(user_id, &1))
        if Enum.all?(results, &(&1 == :ok)), do: {:ok, device_ids}, else: {:error, :unavailable}

      {:error, reason} ->
        Logger.warning("oauth session end: could not list the user's OAuth devices (#{describe(reason)})")
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Ends EVERY device of the user with its keys AND every `matrix_sessions` row of the user (any
  `auth_api`) — Matrix `POST /logout/all`, R17 oracle correction + review cycle 1 (Kassandra F-1/F-2).
  The device set is the union of the user's `devices` rows and `matrix_sessions` device ids (so a session
  without a device row cannot survive); each device gets the ATOMIC, locked teardown of
  `end_device_session/2` (devices-row lock, then all matrix_sessions rows of the device, then the device
  tables, one transaction; lock order devices -> matrix_sessions) plus the JWT kill-switch. Cross-signing
  keys (per user) are kept. A failure of any device (or of the listing) is `{:error, :unavailable}` — the
  caller must not report success — while the remaining devices are still attempted. A login that commits
  after a device's teardown survives whole (session AND device): point-in-time semantics.
  """
  @spec end_all_devices(String.t()) :: :ok | {:error, :unavailable}
  def end_all_devices(user_id) when is_binary(user_id) do
    # The OAuth-session repo test seam (`:oauth_session_repo`) is deliberately NOT applied here: step 3 of
    # `/logout/all` is independent of the OAuth part, which is what its tests model with that seam.
    repo = Nebu.Repo

    case OAuthSessionStore.all_device_ids(user_id, repo) do
      {:ok, device_ids} ->
        results =
          Enum.map(device_ids, fn device_id ->
            case OAuthSessionStore.end_device(user_id, device_id, repo) do
              :ok ->
                after_commit(user_id, device_id)
                :ok

              {:error, reason} ->
                Logger.warning("oauth logout/all: device teardown failed (#{describe(reason)})", device_id: device_id)
                :error
            end
          end)

        if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :unavailable}

      {:error, reason} ->
        Logger.warning("oauth logout/all: could not list the user's devices (#{describe(reason)})")
        {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # ── client revocation (story oauth-client-revocation, CR4 / CR10) ─────────────────────────

  @doc """
  See `Nebu.Matrix.oauth_end_client_sessions/2`: runs INSIDE the caller's transaction (`repo` is its repo);
  no post-commit part here (`after_device_teardown/1` after the COMMIT). `{:ok, [{user_id, device_id}]}` or
  `{:error, reason}` (the caller rolls back). Never raises.
  """
  @spec end_client_sessions(String.t(), module()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def end_client_sessions(client_id, repo) when is_binary(client_id) do
    OAuthSessionStore.end_client_devices(client_id, repo)
  rescue
    e -> {:error, {:exception, e.__struct__}}
  catch
    :exit, _ -> {:error, :exit}
  end

  @doc "See `Nebu.Matrix.oauth_after_device_teardown/1`: the best-effort post-commit part for every pair."
  @spec after_device_teardown([{String.t(), String.t()}]) :: :ok
  def after_device_teardown(pairs) when is_list(pairs) do
    Enum.each(pairs, fn {user_id, device_id} -> after_commit(user_id, device_id) end)
  end

  @doc "See `Nebu.Matrix.oauth_end_all_sessions/0`."
  @spec end_all_sessions() :: {:ok, non_neg_integer()} | {:error, {:unavailable, non_neg_integer()}}
  def end_all_sessions, do: end_all_sessions(nil, 0, 0)

  @all_batch 500

  defp end_all_sessions(cursor, ended, failed) do
    case OAuthSessionStore.oauth_device_pairs(cursor, @all_batch) do
      {:ok, []} ->
        if failed == 0, do: {:ok, ended}, else: {:error, {:unavailable, ended}}

      {:ok, pairs} ->
        results = Enum.map(pairs, fn {user_id, device_id} -> end_device_session(user_id, device_id) end)
        ok = Enum.count(results, &(&1 == :ok))
        end_all_sessions(List.last(pairs), ended + ok, failed + (length(results) - ok))

      {:error, reason} ->
        Logger.warning("oauth session end: could not list the OAuth devices (#{describe(reason)})")
        {:error, {:unavailable, ended}}
    end
  end

  # R2, best effort, AFTER the commit: raw IdP JWTs bound to the device (normally none, T25) and the
  # per-device legacy `sessions` / `sync_tokens` rows. Never fails the revocation.
  defp after_commit(user_id, device_id) do
    kill_bound_jwts(user_id, device_id)

    try do
      _ = Nebu.Matrix.Session.SessionSupervisor.destroy_session(user_id, device_id)
    rescue
      e -> Logger.warning("oauth session end: legacy session cleanup failed: #{inspect(e.__struct__)}")
    catch
      :exit, _ -> :ok
    end

    :ok
  end

  defp describe({:exception, mod}) when is_atom(mod), do: inspect(mod)
  defp describe(reason) when is_atom(reason), do: inspect(reason)
  defp describe(_reason), do: "error"

  # Test-only seams, compile-time guarded (Dev Notes "Test-only seams"). `:oauth_idp_lease_wait_ms` shortens
  # the follower's wait budget; `:oauth_idp_lease_wait_notify` (a pid) receives `{:lease_wait, follower_pid}`
  # when a follower first finds the lease held, so a test releases the holder only AFTER the follower waits
  # (no sleeps decide an outcome).
  if Mix.env() == :test do
    defp seam(key, default), do: Application.get_env(:nebu_http, key, default)

    defp notify_wait do
      case Application.get_env(:nebu_http, :oauth_idp_lease_wait_notify) do
        pid when is_pid(pid) -> send(pid, {:lease_wait, self()})
        _ -> :ok
      end
    end
  else
    defp seam(_key, default), do: default
    defp notify_wait, do: :ok
  end
end
