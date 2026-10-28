defmodule Nebu.Matrix do
  @moduledoc """
  Public API for the Matrix domain (ADR-020).

  This module is the **only** entry point other domains (`Nebu.Admin`, `Nebu.Media`,
  `Nebu.Web`) may call into the Matrix domain. Internal Matrix modules
  (`Nebu.Matrix.Room.*`, `Nebu.Matrix.Session.*`, `Nebu.Matrix.EventDispatcher.*`,
  `Nebu.Matrix.Presence.*`, `Nebu.Matrix.Permissions.*`, `Nebu.Matrix.Signature.*`,
  …) are private to the domain and must not be called directly from outside it.

  Kassandra flags any cross-domain call into `Nebu.Matrix.*` (other than this module)
  as a finding.

  The Matrix domain owns: rooms and room state, the event log and dispatch, sync,
  sessions/tokens, presence, typing, receipts, profiles, power levels, message
  signing, and the Matrix Client-Server HTTP surface.

  `defdelegate` entries are added here as concrete cross-domain operations are
  introduced; today the in-process callers within the Matrix domain use the internal
  modules directly, and no other domain reaches into Matrix internals.

  ## Account management (story oauth-account-management)

  The OAuth domain's account page (`/account`) reads and updates the Matrix-owned `users`, `profiles`,
  `devices` and `uia_sessions` ONLY through `account_identity/1`, `account_devices/1`,
  `account_profile/1`, `cross_signing_reset_requests/1`, `approve_cross_signing_reset/2` and
  `decline_cross_signing_reset/2` (plus the existing `end_device_session/2` and the IdP functions);
  `purge_expired_uia_sessions/0` serves the periodic purge. All are error-aware and never raise.

  ## Client revocation (story oauth-client-revocation)

  `oauth_end_client_sessions/2` (INSIDE the caller's transaction), `oauth_after_device_teardown/1` (after its
  commit), `oauth_client_session_counts/1` (the admin list) and `oauth_end_all_sessions/0` (the operator kill
  switch) serve the OAuth domain's withdrawal of a client. `oauth_issue_session/1` and the refresh rotation
  lock the client row `FOR SHARE` first (decision CR5, the one cross-table read of this domain).

  ## Spaces S5 — Admin Spaces management surface

  The Admin UI (`Nebu.Admin.SpacesLive`) manages Spaces through this module only
  (ADR-020). Each function below routes to the same authorized in-process command
  path the Matrix HTTP routers use (`Nebu.Matrix.EventDispatcher.Server`), so admin
  writes go through the identical signing / power-level / allowlist checks — there is
  no second, unauthorised write path. The admin acts as a Matrix user (`actor_id`):
  for `create_space/2` that user becomes the room creator (power level 100); for
  `set_space_state/5` the actor must be a member with the power to set state (the S2
  `set_room_state` authorization).
  """

  alias Nebu.Matrix.EventDispatcher.Server, as: Dispatcher

  @doc """
  Provisions (or re-provisions, idempotently) a Matrix `users`-row for `user_id`,
  WITHOUT triggering auto-join / personal-room onboarding (story
  `provision-matrix-identity-on-admin-login`, epic `oidc-simplification`).

  This is the narrow, non-onboarding half of the real Matrix `/login`
  provisioning flavor (`Nebu.Matrix.HttpPublic.provision_and_respond/6`):
  `Nebu.Matrix.Session.TokenValidator.validate/4` (creates the row on first
  sight, else a no-op idempotent lookup) followed by
  `Nebu.Matrix.Profile.DB.upsert_profile/3` (nil-safe `COALESCE` upsert — never
  clobbers a displayname the person set themselves). Unlike
  `provision_and_respond/6`, this function deliberately does NOT call
  `Nebu.Matrix.EventDispatcher.Server.run_post_login_provisioning/2` — see the
  "Implementation Decision" note under AC2 of the story for the rationale
  (admin-only logins should not auto-join a person into every `is_auto_join`
  room merely because they authenticated once in the Admin UI).

  ADR-020: this is the ONLY way `Nebu.Admin` may reach this provisioning logic
  — it must never call `Nebu.Matrix.Session.TokenValidator` or
  `Nebu.Matrix.Profile.DB` directly.

  Grants no Matrix permissions beyond what any freshly-provisioned `user_id`
  already has (room actions remain gated by their own membership/power-level
  checks) — provisioning alone is not a privilege-escalation path.

  Returns `{:ok, user_id}` on success (including the idempotent re-provisioning
  case), or `{:error, reason}` (e.g. `{:error, :deactivated}` for a
  deprovisioned identity).
  """
  @spec provision_identity(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def provision_identity(user_id, opts \\ []) when is_binary(user_id) do
    if repo_reachable?() do
      system_role = opts[:system_role] || "user"
      display_name = opts[:display_name] || ""
      email = opts[:email] || ""

      case Nebu.Matrix.Session.TokenValidator.validate(user_id, system_role, display_name, email) do
        {:ok, user} ->
          dn = if display_name in [nil, ""], do: nil, else: display_name
          maybe_upsert_profile(user.user_id, dn)
          {:ok, user.user_id}

        {:error, _reason} = err ->
          err
      end
    else
      {:error, :repo_not_started}
    end
  end

  # `TokenValidator.validate/4` is DI-swappable per-test (the SAME
  # `:session_manager, :validator_module` seam the real Matrix /login path
  # uses) — a test-injected fake is safe to call with no live Repo. The
  # DEFAULT `Postgres` implementation, however, always issues a real
  # `Ecto.Adapters.SQL.query(Nebu.Repo, ...)` call, which RAISES (not
  # `{:error, _}`) when `Nebu.Repo` is not started (plain unit test runs, no
  # `NEBU_DB_URL`) — so does `Profile.DB.upsert_profile/3` further down this
  # same call graph. Only skip the whole provisioning attempt when we are
  # about to hit the real (non-test-overridden) Postgres path with no Repo
  # running; a test-injected validator_module always proceeds regardless of
  # Repo state, matching the ATDD seam's contract.
  defp repo_reachable? do
    Process.whereis(Nebu.Repo) != nil or validator_overridden_for_test?()
  end

  defp validator_overridden_for_test? do
    Application.get_env(:session_manager, :validator_module) not in [nil, Nebu.Matrix.Session.TokenValidator.Postgres]
  end

  # Mirrors provision_and_respond/6's unconditional upsert_profile/3 call, guarded
  # by the same live-Repo check: `Profile.DB.upsert_profile/3` always issues a real
  # `Ecto.Adapters.SQL.query(Nebu.Repo, ...)` call (no DI seam), which would raise
  # if reached without a running Repo — this can only be reached here when
  # `repo_reachable?/0` already confirmed either a running Repo or a test-injected
  # validator (whose ATDD seam's fake `validate/4` never touches Profile.DB itself,
  # only the real Postgres validator's callers do), so skip it defensively when
  # Repo genuinely is not running (test-injected-validator path).
  defp maybe_upsert_profile(user_id, display_name) do
    if Process.whereis(Nebu.Repo) != nil do
      _ = Nebu.Matrix.Profile.DB.upsert_profile(user_id, display_name, nil)
    end

    :ok
  end

  # ── IdP leg of the OAuth broker (epic oauth-broker, story oauth-authorize-idp-delegation-code,
  #    D22) ─────────────────────────────────────────────────────────────────────
  #
  # The Matrix domain owns the ONE IdP client (ADR-022) and its registered callback; the OAuth
  # domain (`Nebu.OAuth`) reaches the IdP only through these three functions (ADR-020) and never
  # calls `Nebu.Matrix.SsoLogin` / `SsoStore` / `TokenValidator` directly.

  @doc """
  Builds the IdP authorization URL for an OAuth-broker flow (story oauth-authorize-idp-delegation-code
  AC6), with the SAME builder as the legacy `/sso/redirect` (the one IdP client, the shared
  registered callback derived from `conn`'s Host / `X-Forwarded-Proto`, the OIDC Scopes Law,
  PKCE S256, `prompt=login`; `prompt=create` only when `params.prompt == "create"` and the IdP
  advertises it). `params`: `%{state: oauth_tagged_state, prompt: "create" | nil}`.

  Nothing is stored node-locally: returns `{:ok, %{location:, verifier:, nonce:}}` (the caller
  persists the IdP PKCE verifier and nonce), or `{:error, reason}` when the IdP configuration or
  its discovery document is unavailable.
  """
  @spec idp_authorize_location(Plug.Conn.t(), map()) ::
          {:ok, %{location: String.t(), verifier: String.t(), nonce: String.t()}} | {:error, term()}
  def idp_authorize_location(conn, params) when is_map(params) do
    Nebu.Matrix.SsoLogin.oauth_idp_authorize_location(conn, params)
  end

  @doc """
  Completes the IdP leg of an OAuth-broker flow at the shared callback (AC7.10): exchanges the
  IdP `code` (with the IdP PKCE `verifier`), verifies the id_token through the single shared
  verification path and checks the IdP `nonce` — the same function the legacy callback uses.

  `{:ok, %{claims:, idp_refresh_token: binary | nil}}`, `{:error, :idp_unavailable}` (IdP
  unreachable / 5xx / configuration or discovery missing) or `{:error, :idp_rejected}` (anything
  else: verification, nonce, malformed token response). Error details are not returned (they may
  carry IdP-supplied text).
  """
  @spec idp_complete_login(Plug.Conn.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{claims: map(), idp_refresh_token: String.t() | nil}}
          | {:error, :idp_unavailable | :idp_rejected}
  def idp_complete_login(conn, code, verifier, nonce) do
    case Nebu.Matrix.SsoLogin.complete_idp_login(conn, code, verifier, nonce) do
      {:ok, %{claims: claims, idp_refresh_token: rt}} -> {:ok, %{claims: claims, idp_refresh_token: rt}}
      {:error, reason} -> {:error, classify_idp_error(reason)}
    end
  rescue
    # Infrastructure trouble (e.g. the HTTP client / config read crashed), NOT an IdP verdict:
    # temporarily_unavailable for the client. Only the exception type is logged (never details).
    e ->
      require Logger
      Logger.warning("Matrix.idp_complete_login: unexpected #{inspect(e.__struct__)}")
      {:error, :idp_unavailable}
  catch
    # An exit (a crashed / timed-out pool or GenServer call underneath): the same outcome. Only the word `exit`
    # is logged, never the exit reason (story oauth-hardening-hygiene, HY8 / I-13).
    :exit, _reason ->
      require Logger
      Logger.warning("Matrix.idp_complete_login: unexpected exit")
      {:error, :idp_unavailable}
  end

  defp classify_idp_error({:token_endpoint_unreachable, _}), do: :idp_unavailable
  defp classify_idp_error({:token_endpoint_status, status}) when is_integer(status) and status >= 500, do: :idp_unavailable
  defp classify_idp_error({:discovery_failed, _}), do: :idp_unavailable
  defp classify_idp_error({:discovery_missing, _}), do: :idp_unavailable
  defp classify_idp_error(:issuer_not_configured), do: :idp_unavailable
  defp classify_idp_error(:client_id_not_configured), do: :idp_unavailable
  defp classify_idp_error(_other), do: :idp_rejected

  @doc """
  Provisions the Matrix user of verified IdP `claims` at the OAuth-broker callback (D18): the SAME
  provisioning as the legacy `POST /login` (`UserId.from_claims/2`, `TokenValidator.validate/4`,
  profile upsert, post-login provisioning with `is_new` — personal room / auto-join), but NO device
  registration and no session (story 3). Unlike `provision_identity/2` it DOES run the post-login
  provisioning.

  `{:ok, %{user_id:, auth_time: unix_seconds | nil}}` (auth_time = id_token `auth_time`, else
  `iat`), `{:error, :deactivated}` or `{:error, reason}`. Never raises.
  """
  @spec provision_login_user(map()) :: {:ok, %{user_id: String.t(), auth_time: integer() | nil}} | {:error, term()}
  def provision_login_user(claims) when is_map(claims) do
    Nebu.Matrix.SsoLogin.provision_login_user(claims)
  rescue
    e -> {:error, {:provisioning_failed, e.__struct__}}
  end

  # ── Legacy SSO redirect origins (story legacy-sso-redirect-confirmation, G3-3, D5) ──────────
  #
  # The Admin domain validates the operator list of https origins only through this function (ADR-020): ONE
  # validator, shared with the callback's allowlist check.

  @doc """
  Validates and normalizes the operator list of origins whose legacy SSO logins skip the confirmation page
  (`server_config.sso_redirect_allowed_origins`, story legacy-sso-redirect-confirmation, D5): a comma separated
  list of https origins (scheme, host, optional port; no path, query, fragment, userinfo or wildcard). Returns
  `{:ok, normalized}` (lower case, `:443` and a trailing `/` dropped, duplicates removed, comma + space
  separated; `""` for an empty list) or `{:error, message}` naming the offending token (truncated to 80
  characters; render it escaped, never log it). Nothing is partially accepted.
  """
  @spec normalize_sso_redirect_origins(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_sso_redirect_origins(raw), do: Nebu.Matrix.SsoRedirect.normalize_origin_list(raw)

  # ── OAuth sessions (epic oauth-broker, story oauth-token-endpoint, T1) ─────────
  #
  # OAuth sessions are rows of the Matrix-owned `matrix_sessions` table (`auth_api = 'oauth'`), so
  # every session read/write is Matrix domain. The OAuth token endpoint (`Nebu.OAuth.Token`) calls
  # ONLY these five functions (ADR-020); it never names `Nebu.Matrix.Session.*`,
  # `Nebu.Matrix.HttpPublic` or `Nebu.Matrix.DeviceKeyStore`. None of them raises.

  @doc """
  Issues an OAuth session for a redeemed authorization code (story oauth-token-endpoint, AC7).

  `attrs`: `user_id`, `device_id`, `client_id`, `scope` (the granted scope string, stored
  verbatim), `oauth_code_hash`, `idp_rt_enc` (the code row's SecretBox ciphertext of the IdP
  refresh token or nil — stored, never decrypted here), `auth_time` (unix seconds or nil),
  `access_ttl_seconds`.

  Error-aware `is_active` check first (T19), then ONE transaction: the `devices` row is upserted
  (kept with its E2EE keys when the id is reused), EVERY earlier `matrix_sessions` row of
  `(user_id, device_id)` (legacy and OAuth) is deleted and the new row inserted (`expires_at =
  LEAST(now() + ttl, session_expires_at)`, `session_expires_at = now() +
  NEBU_MATRIX_SESSION_TTL_SECONDS`). Afterwards raw IdP JWTs bound to the device are denylisted.

  `{:ok, %{access_token:, refresh_token:, expires_in:, user_id:, device_id:, scope:, auth_time:}}`,
  `{:error, :inactive}` (deactivated or unknown user) or `{:error, :unavailable}` (transient).
  """
  @spec oauth_issue_session(map()) :: {:ok, map()} | {:error, :inactive | :unavailable | :device_in_use | :client_not_approved}
  def oauth_issue_session(attrs) when is_map(attrs) do
    Nebu.Matrix.OAuthSession.issue(attrs)
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Classifies an OAuth refresh token (AC9, T10/T11/T27): `{:ok, session, :current}` (the device's
  active row), `{:ok, session, :replay}` (a rotated-away but still PENDING token: `session` is the
  device's ACTIVE row), `{:reused, session}` (a CONSUMED token of an alive session),
  `:error` (unknown, legacy, an access token, expired session) or `{:error, :unavailable}`.

  `session` carries `user_id`, `device_id`, `client_id`, `scope`, `session_expires_at`,
  `auth_time` and internal row data (hashes, the IdP refresh-token ciphertext) the caller passes
  back unchanged to `oauth_refresh_session/4`.
  """
  @spec oauth_resolve_refresh_token(String.t()) ::
          {:ok, map(), :current | :replay} | {:reused, map()} | :error | {:error, :unavailable}
  def oauth_resolve_refresh_token(refresh_token), do: Nebu.Matrix.OAuthSession.resolve_refresh_token(refresh_token)

  @doc """
  Refreshes an OAuth session (AC9/AC10): IdP re-validation (`idp_revalidation: :per_refresh` — the
  stored IdP refresh token is redeemed and the user re-checked; `:off` — only `users.is_active`),
  then the rotation (new access AND refresh token; the old refresh token stays redeemable until the
  new tokens are used). `opts`: `%{scope:, idp_revalidation:, access_ttl_seconds:}` (`scope` = the
  new granted scope, already narrowed by the caller).

  `{:ok, %{access_token:, refresh_token:, expires_in:, scope:, user_id:, device_id:, auth_time:}}`,
  `{:error, :invalid_grant}` (the session was revoked where the error mapping says so: reuse,
  confirmed IdP rejection, deactivation) or `{:error, {:unavailable, retry_after_s}}` (transient:
  the session is untouched and the same refresh token works on retry).
  """
  @spec oauth_refresh_session(map(), :current | :replay, String.t(), map()) ::
          {:ok, map()} | {:error, :invalid_grant} | {:error, {:unavailable, pos_integer()}}
  def oauth_refresh_session(session, mode, refresh_token, opts),
    do: Nebu.Matrix.OAuthSession.refresh(session, mode, refresh_token, opts)

  @doc """
  Ends EVERY session and device of an OAuth client INSIDE the caller's database transaction (story
  oauth-client-revocation, CR4 step 2): the `(user_id, device_id)` pairs that have a `matrix_sessions` row of
  `client_id` (any state) are torn down one by one with the locked teardown of `oauth_end_device/2`'s engine
  (devices row `FOR UPDATE`, every session row of the device, device / one-time / fallback keys; lock order
  oauth_clients -> devices -> matrix_sessions), then the client must have 0 session rows left. `repo` is the
  repo of the caller's transaction (the nested transactions join it).

  `{:ok, [{user_id, device_id}]}` or `{:error, reason}` — the caller MUST roll its transaction back; after the
  COMMIT it calls `oauth_after_device_teardown/1`. Never raises.
  """
  @spec oauth_end_client_sessions(String.t(), module()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def oauth_end_client_sessions(client_id, repo) when is_binary(client_id) and is_atom(repo),
    do: Nebu.Matrix.OAuthSession.end_client_sessions(client_id, repo)

  @doc """
  The best-effort part of a teardown that must run AFTER the commit, for each `{user_id, device_id}`: the
  JWT denylist + binding deletion of the device and its per-device legacy session rows. `:ok`; never raises.
  """
  @spec oauth_after_device_teardown([{String.t(), String.t()}]) :: :ok
  def oauth_after_device_teardown(pairs) when is_list(pairs) do
    Nebu.Matrix.OAuthSession.after_device_teardown(pairs)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Live sessions per OAuth client for the admin list: `{:ok, %{client_id => devices}}` (a client without a live
  session is absent) or `{:error, :unavailable}` (the admin shows `?`, never `0`). Never raises.
  """
  @spec oauth_client_session_counts([String.t()]) :: {:ok, %{String.t() => non_neg_integer()}} | {:error, :unavailable}
  def oauth_client_session_counts(client_ids) when is_list(client_ids) do
    case Nebu.Matrix.Session.OAuthSessionStore.client_session_counts(client_ids) do
      {:ok, counts} -> {:ok, counts}
      {:error, _} -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Ends EVERY OAuth session of EVERY user (operator kill switch, story oauth-client-revocation, CR10): each
  device with an `auth_api = 'oauth'` row gets the atomic teardown of `end_device_session/2` (batches of 500).
  Legacy-only devices are untouched. `{:ok, devices_ended}` or `{:error, {:unavailable, devices_ended_so_far}}`
  (the remaining devices are still attempted; re-run). Never raises.
  """
  @spec oauth_end_all_sessions() :: {:ok, non_neg_integer()} | {:error, {:unavailable, non_neg_integer()}}
  def oauth_end_all_sessions do
    Nebu.Matrix.OAuthSession.end_all_sessions()
  rescue
    _ -> {:error, {:unavailable, 0}}
  catch
    :exit, _ -> {:error, {:unavailable, 0}}
  end

  @doc """
  Revokes the OAuth session of a device: deletes every `auth_api = 'oauth'` row of
  `(user_id, device_id)` (refresh-token reuse, T11). `:ok` or `{:error, :unavailable}`.
  """
  @spec oauth_revoke_device_session(String.t(), String.t()) :: :ok | {:error, :unavailable}
  def oauth_revoke_device_session(user_id, device_id),
    do: Nebu.Matrix.OAuthSession.revoke_device_session(user_id, device_id)

  @doc """
  Revokes the session derived from an authorization code (code reuse, RFC 9700 / T8): deletes every
  `auth_api = 'oauth'` row of the device(s) whose rows carry `oauth_code_hash = code_hash` (also
  after rotations). `{:ok, [{user_id, device_id}]}` or `{:error, :unavailable}`.
  """
  @spec oauth_revoke_sessions_for_code(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, :unavailable}
  def oauth_revoke_sessions_for_code(code_hash),
    do: Nebu.Matrix.OAuthSession.revoke_sessions_for_code(code_hash)

  @doc """
  Revokes an OAuth session by ANY of its tokens (RFC 7009 / Matrix "Token revocation", story
  oauth-token-revocation-logout, R2/R24): the access OR refresh token, in ANY state (active, expired
  access token, superseded, pending/consumed refresh token, expired session). Ends the WHOLE session
  of the device in one atomic transaction under the devices-row lock shared with issuance and
  rotation: every `matrix_sessions` row of `(user_id, device_id)` (incl. the IdP refresh-token
  ciphertext), the `devices` row with its E2EE key material; afterwards, best effort, bound raw-JWT
  credentials and per-device legacy session rows. Also the engine of OAuth `POST /logout`.

  `{:ok, :revoked, %{user_id:, device_id:, client_id:}}` (the STORED client id), `{:ok, :unknown}`
  (unknown / already revoked / legacy / not a 64-hex token: nothing touched, no DB access for a
  malformed value) or `{:error, :unavailable}` (database error, rolled back). Never raises.
  """
  @spec oauth_revoke_token(term()) ::
          {:ok, :revoked, %{user_id: String.t(), device_id: String.t(), client_id: String.t()}}
          | {:ok, :unknown}
          | {:error, :unavailable}
  def oauth_revoke_token(token) do
    Nebu.Matrix.OAuthSession.revoke_token(token)
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Legacy `POST /logout` (opaque Nebu token or raw IdP JWT bound to a device; bugfix legacy-logout-per-device,
  LL1-LL10): ends ONLY the device the presented credential is bound to, with the same atomic, locked teardown
  as `oauth_revoke_token/1` (every session row of the device, the device, its device / one-time / fallback
  keys; afterwards the JWT kill-switch and the per-device legacy sessions). The credential is re-checked under
  the devices-row lock: when it no longer belongs to the device (an OAuth login took the device id over, a
  concurrent logout won) nothing is deleted.

  Takes `%{kind: :opaque | :jwt, token: String.t(), user_id: String.t(), device_id: String.t()}` (user and
  device come from the authentication assigns, never from request input). Returns `{:ok, :ended}`,
  `{:ok, :unknown}` (nothing deleted; the credential is already invalid) or `{:error, :unavailable}` (storage
  failure, rolled back). Never raises.
  """
  @spec legacy_logout_device(%{kind: :opaque | :jwt, token: String.t(), user_id: String.t(), device_id: String.t()}) ::
          {:ok, :ended} | {:ok, :unknown} | {:error, :unavailable}
  def legacy_logout_device(%{} = req) do
    Nebu.Matrix.OAuthSession.end_legacy_device(req)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  Ends every OAuth session of a user (`POST /logout/all`, GDPR erasure; R17/R19/R24): for every device
  with an `auth_api = 'oauth'` row the same teardown as `oauth_revoke_token/1` (rows, device, keys).
  Legacy rows and devices are NOT touched here (see `end_all_user_devices/1`).
  `{:ok, [device_id]}` (a second call returns `{:ok, []}`) or `{:error, :unavailable}` (the remaining
  devices are still attempted). Never raises.
  """
  @spec oauth_end_user_sessions(String.t()) :: {:ok, [String.t()]} | {:error, :unavailable}
  def oauth_end_user_sessions(user_id) when is_binary(user_id) do
    Nebu.Matrix.OAuthSession.end_all_for_user(user_id)
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Deletes EVERY device of the user with its keys (Matrix `POST /logout/all`: "deletes all devices
  and their keys", R17): per device the JWT kill-switch and the device tables (device identity,
  device keys, one-time and fallback keys). Cross-signing keys (per user) are kept. Idempotent.
  `:ok` or `{:error, :unavailable}` (the remaining devices are still attempted). Never raises.
  """
  @spec end_all_user_devices(String.t()) :: :ok | {:error, :unavailable}
  def end_all_user_devices(user_id) when is_binary(user_id) do
    Nebu.Matrix.OAuthSession.end_all_devices(user_id)
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Returns `true` if `user_id` is a known Matrix user with `is_active = true` that is not erased,
  `false` if the user is deactivated, erased (`deletion_status IS NOT NULL`, story
  gdpr-erasure-global-data D17) OR unknown (fail-closed — an absent
  `users` row grants nothing).

  Read-only — unlike `provision_identity/2` this never inserts/upserts a row,
  it only reports the SAME account-deactivation signal
  (`{:error, :deactivated}`) that `provision_identity/2` and the `/login` path
  (`Nebu.Matrix.Session.TokenValidator`) already use. Added for
  `Nebu.Media.Permission.can_upload?/1` (media-security-admin-control/
  2a-post-media-create, AC4) — ADR-020: this is the only sanctioned way
  `Nebu.Media` may read Matrix account state.
  """
  @spec active?(String.t()) :: boolean()
  def active?(user_id) when is_binary(user_id) do
    case Ecto.Adapters.SQL.query(Nebu.Repo, "SELECT (is_active AND deletion_status IS NULL) FROM users WHERE user_id = $1", [
           user_id
         ]) do
      {:ok, %{rows: [[true]]}} -> true
      _ -> false
    end
  end

  @doc """
  Creates a Matrix Space (a room with `creation_content.type = "m.space"`), with
  `creator_id` as the creator (power level 100). `name` may be `nil`/`""`.

  Returns `{:ok, room_id}` or `{:error, reason}`. Routes through the authorized
  createRoom command path (Spaces S1) — same signing/persistence as a client create.
  """
  @spec create_space(String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def create_space(creator_id, name) do
    req = %Core.CreateRoomRequest{
      creator_id: creator_id,
      name: name || "",
      is_direct: false,
      room_type: "m.space",
      creation_content_json: Jason.encode!(%{"type" => "m.space"})
    }

    try do
      %Core.CreateRoomResponse{room_id: room_id} = Dispatcher.create_room(req, nil)
      {:ok, room_id}
    rescue
      e in Nebu.Matrix.Error -> {:error, e.message}
    end
  end

  @doc """
  Writes a state event into a Space through the S2 authorized `set_room_state` path
  (allowlist + membership + power-level check). Used by the Admin UI to edit a
  Space's name/topic (`m.room.name` / `m.room.topic`) and to add/remove child rooms
  (`m.space.child` with content / empty-content unlink).

  `sender_id` is the acting admin's Matrix user id. `content` is a plain map.

  Audit (story `space-edit-audit`, follow-up `dj`): after a SUCCESSFUL write exactly one
  `audit_log` row is written for the four admin edits (`m.room.name` -> `space_name_changed`,
  `m.room.topic` -> `space_topic_changed`, `m.space.child` with content ->
  `space_child_added`, with an empty content map -> `space_child_removed`); any other event
  type and every `{:error, _}` write no row. The row is NOT atomic with the event (the event
  goes through the Room GenServer): a raising / exiting / failing audit writer is logged
  (action, room id and error kind only, never a name or a topic) and never changes the
  return value. The generic client path (`Dispatcher.set_room_state/2`) writes no row: a
  Matrix client edit is not an admin action.

  Returns `{:ok, event_id}` or `{:error, reason}`.
  """
  @spec set_space_state(String.t(), String.t(), String.t(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def set_space_state(room_id, sender_id, event_type, state_key, content)
      when is_map(content) do
    req = %Core.SetRoomStateRequest{
      room_id: room_id,
      sender_id: sender_id,
      event_type: event_type,
      state_key: state_key || "",
      content_json: Jason.encode!(content)
    }

    # The audit call is OUTSIDE the try/rescue of the state write: the Nebu.Matrix.Error of the write
    # itself is the only thing turned into {:error, _}; the audit never changes that.
    result =
      try do
        %Core.SetRoomStateResponse{event_id: event_id} = Dispatcher.set_room_state(req, nil)
        {:ok, event_id}
      rescue
        e in Nebu.Matrix.Error -> {:error, e.message}
      end

    with {:ok, event_id} <- result do
      audit_space_edit(room_id, sender_id, event_type, req.state_key, content, event_id)
      result
    end
  end

  # Space-edit audit (story space-edit-audit, D1 - D3). Never raises and never exits: the
  # metadata building and the writer call sit in ONE protected block, the edit itself is
  # already persisted. Only the action, the room id and the error KIND are logged.
  @spec audit_space_edit(String.t(), String.t(), String.t(), String.t(), map(), String.t()) :: :ok
  defp audit_space_edit(room_id, sender_id, event_type, state_key, content, event_id) do
    case space_audit_action(event_type, content) do
      nil ->
        :ok

      action ->
        try do
          metadata = space_audit_metadata(action, state_key, content, event_id)
          writer = Application.get_env(:compliance, :audit_writer, Nebu.Compliance.AuditWriter)

          case writer.log(sender_id, action, "room", room_id, metadata, "success") do
            :ok -> :ok
            other -> log_space_audit_failure(action, room_id, error_kind(other))
          end
        rescue
          e -> log_space_audit_failure(action, room_id, inspect(e.__struct__))
        catch
          :exit, _ -> log_space_audit_failure(action, room_id, "exit")
        end
    end
  end

  # `nil` = this event type is not an audited space edit.
  defp space_audit_action("m.room.name", _content), do: "space_name_changed"
  defp space_audit_action("m.room.topic", _content), do: "space_topic_changed"
  defp space_audit_action("m.space.child", content) when content == %{}, do: "space_child_removed"
  defp space_audit_action("m.space.child", _content), do: "space_child_added"
  defp space_audit_action(_type, _content), do: nil

  # D2 / D5 / D7: name and topic are cut to 256 CHARACTERS (not bytes), `child_room_id` is not cut;
  # the event id links the row to the `events` record.
  defp space_audit_metadata("space_name_changed", _key, content, event_id),
    do: %{"name" => audit_slice(content["name"]), "event_id" => event_id}

  defp space_audit_metadata("space_topic_changed", _key, content, event_id),
    do: %{"topic" => audit_slice(content["topic"]), "event_id" => event_id}

  defp space_audit_metadata(_child_action, key, _content, event_id),
    do: %{"child_room_id" => key, "event_id" => event_id}

  # a non-string value (malformed content) is kept out of the row instead of crashing the metadata
  # 256 graphemes AND at most 1024 bytes (String.slice/3 counts graphemes: a value of one grapheme with many combining marks would
  # otherwise stay unbounded); the byte cut keeps only whole valid UTF-8 characters (Kassandra short review, LOW-1).
  @audit_value_max_bytes 1024
  defp audit_slice(value) when is_binary(value) do
    sliced = String.slice(value, 0, 256)

    if byte_size(sliced) <= @audit_value_max_bytes do
      sliced
    else
      sliced |> binary_part(0, @audit_value_max_bytes) |> String.chunk(:valid) |> List.first() |> Kernel.||("")
    end
  end

  defp audit_slice(_), do: nil

  defp error_kind({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_kind(_), do: "error"

  defp log_space_audit_failure(action, room_id, kind) do
    require Logger
    Logger.error("space edit audit not written: action=#{action} room=#{room_id} kind=#{kind}")
    :ok
  end

  @doc """
  Returns the current `m.space.child` edges of `space_id` as `{:ok, [{child_room_id,
  content_map}]}` (Spaces S3). Empty (unlinked) children are already dropped.
  """
  @spec get_space_children(String.t()) :: {:ok, [{String.t(), map()}]} | {:error, term()}
  defdelegate get_space_children(space_id), to: Nebu.Matrix.Room.DB

  @doc """
  Returns all auto-join Space room IDs (`room_type = 'm.space' AND is_auto_join AND
  status = 'active'`). Spaces S5 (AC6).
  """
  @spec list_auto_join_spaces() :: {:ok, [String.t()]} | {:error, term()}
  defdelegate list_auto_join_spaces, to: Nebu.Matrix.Room.DB

  @doc """
  Auto-joins `user_id` to every flagged Space (first-login provisioning). Non-fatal.
  Spaces S5 (AC6).
  """
  @spec ensure_auto_join_space_memberships(String.t()) :: :ok
  defdelegate ensure_auto_join_space_memberships(user_id), to: Dispatcher

  @doc """
  Persists the `is_auto_join` flag for a Space (or room) and emits the audit_log
  entry, performed as `actor_id` (Spaces S5 AC5). This is the same audited write the
  `update_room_settings` command path uses for the rooms admin toggle — a Space is a
  room, so the persistence + audit are identical. Routed through the Matrix domain so
  the Admin UI never reaches into Matrix/Admin internals directly (ADR-020).

  Returns `:ok` or `{:error, reason}`.
  """
  @spec set_room_auto_join(String.t(), String.t(), boolean()) :: :ok | {:error, term()}
  defdelegate set_room_auto_join(actor_id, room_id, value), to: Dispatcher

  @doc """
  Persists a room's `visibility` ("public" | "private") and emits the audit_log entry,
  performed as `actor_id` (Story rm1-room-visibility). This is the same audited,
  validated, parameterised write the `update_room_settings` command path performs for
  its visibility branch. Routed through the Matrix domain so the Admin UI never reaches
  into Matrix/Admin internals directly (ADR-020).

  Default-deny: only "public"/"private" are accepted; any other value returns
  `{:error, :invalid_visibility}` without touching the DB.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec set_room_visibility(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate set_room_visibility(actor_id, room_id, visibility), to: Dispatcher

  @doc """
  Adds `user_id` to `room_id` as the acting admin `actor_id` (Story rm4). Wraps the
  SAME authorized join write path the Matrix client flow uses (`join_room`): it emits
  a proper `m.room.member` join event and upserts `room_members` (`left_at = NULL`),
  then writes a `member_added` audit row with the admin as actor.

  Default-deny: `user_id` is shape-validated (`Nebu.Matrix.UserId.valid?/1`) before any
  write; a malformed id returns `{:error, :invalid_user_id}` without touching the DB.
  An unknown room surfaces as `{:error, :not_found}`. Routed through the Matrix domain
  so the Admin UI never reaches into Matrix internals directly (ADR-020).

  Returns `{:ok, room_id}` or `{:error, reason}`.
  """
  @spec admin_add_room_member(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  defdelegate admin_add_room_member(room_id, user_id, actor_id), to: Dispatcher

  @doc """
  Removes `user_id` from `room_id` as the acting admin `actor_id` (Story rm4). Wraps the
  SAME authorized leave write path the Matrix client flow uses (`leave_room`): it emits a
  proper `m.room.member` leave event and sets `room_members.left_at`, then writes a
  `member_removed` audit row with the admin as actor.

  Self-removal is rejected server-side (`{:error, :self_removal}`) so an admin can never
  drop their own membership through this path (defence-in-depth; the UI also hides the
  control). `user_id` is shape-validated before any write. Routed through the Matrix
  domain (ADR-020).

  Returns `:ok` or `{:error, reason}`.
  """
  @spec admin_remove_room_member(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  defdelegate admin_remove_room_member(room_id, user_id, actor_id), to: Dispatcher

  @doc """
  Creates an ordinary Matrix room with `creator_id` as the creator (power level 100),
  through the SAME authorized `createRoom` command path the Matrix `POST /createRoom`
  flow uses (`Nebu.Matrix.EventDispatcher.Server.create_room/2`). The created room is
  audited (`room_created`) with `creator_id` as the actor.

  `opts`:
    * `:name`       — the room name (`m.room.name`); `nil`/`""` leaves it unnamed.
    * `:visibility` — `"public"` | `"private"` (default `"private"`). Passed to the core as the request's
      `visibility` (story create-room-presets-power-levels-topic, D6): a `"public"` room gets the `public_chat`
      preset (join rule `public`, matching its label) and the core stores `rooms.visibility` through the audited
      `set_room_visibility/3` path (exactly one `room_visibility_changed` row); a `"private"` / default room gets
      `private_chat` (join rule `invite`). Any value other than `"public"`/`"private"` returns
      `{:error, :invalid_visibility}` without creating a room (default-deny — same allowlist
      `set_room_visibility/3` enforces).

  Routed through the Matrix domain so the Admin UI never reaches into Matrix internals
  directly (ADR-020).

  Returns `{:ok, room_id}` or `{:error, reason}`.
  """
  @spec create_room(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_room(creator_id, opts \\ []) when is_list(opts) do
    name = opts[:name] || ""
    visibility = opts[:visibility] || "private"

    # Default-deny: validate the visibility allowlist BEFORE creating the room so an
    # invalid value never produces an orphan room. Mirrors set_room_visibility/3.
    if visibility not in ["public", "private"] do
      {:error, :invalid_visibility}
    else
      req = %Core.CreateRoomRequest{
        creator_id: creator_id,
        name: name,
        is_direct: false,
        room_type: "",
        creation_content_json: "",
        visibility: visibility
      }

      try do
        # the core writes the preset events and the (audited, non-fatal) visibility flag
        %Core.CreateRoomResponse{room_id: room_id} = Dispatcher.create_room(req, nil)

        {:ok, room_id}
      rescue
        e in Nebu.Matrix.Error -> {:error, e.message}
      end
    end
  end

  @doc """
  Archives a room as `actor_id` (the acting admin's Matrix user id), through the SAME
  authorized command path the admin archive RPC uses
  (`Nebu.Matrix.EventDispatcher.Server.archive_room/2`): it atomically sets
  `rooms.status='archived'` (SELECT FOR UPDATE), terminates any running Room GenServer
  (best-effort, GenServer-independent), and writes a `room_archived` audit row.

  Returns `:ok`, `{:error, :not_found}` for an unknown room, or `{:error, reason}`.
  Routed through the Matrix domain (ADR-020).
  """
  @spec archive_room(String.t(), String.t()) :: :ok | {:error, :not_found} | {:error, term()}
  def archive_room(actor_id, room_id) do
    req = %Core.ArchiveRoomRequest{room_id: room_id}

    try do
      %Core.ArchiveRoomResponse{ok: true} = Dispatcher.archive_room(req, actor_stream(actor_id))
      :ok
    rescue
      e in Nebu.Matrix.Error -> map_room_error(e)
    end
  end

  @doc """
  Unarchives a room as `actor_id`, through the SAME authorized command path the admin
  unarchive RPC uses (`Nebu.Matrix.EventDispatcher.Server.unarchive_room/2`): it sets
  `rooms.status='active'`, (re)starts the Room GenServer best-effort, and writes a
  `room_unarchived` audit row.

  Returns `:ok`, `{:error, :not_found}`, or `{:error, reason}`. Routed through the
  Matrix domain (ADR-020).
  """
  @spec unarchive_room(String.t(), String.t()) :: :ok | {:error, :not_found} | {:error, term()}
  def unarchive_room(actor_id, room_id) do
    req = %Core.UnarchiveRoomRequest{room_id: room_id}

    try do
      %Core.UnarchiveRoomResponse{ok: true} = Dispatcher.unarchive_room(req, actor_stream(actor_id))
      :ok
    rescue
      e in Nebu.Matrix.Error -> map_room_error(e)
    end
  end

  @doc """
  Invalidates the node-local `oidc_user_id_claim` cache and propagates the
  invalidation across the cluster via `:pg` (story `oidc-claim-boot-cache`,
  ADR-020).

  This is the Public-API entry point (ADR-020) the admin write path calls after
  `Nebu.Admin.DB.upsert_server_config/1` persists a change that includes the
  `oidc_user_id_claim` key — `Nebu.Admin` must never reach into the Matrix-domain
  cache module directly. Triggers a local re-read and a `:pg` broadcast so every
  node refreshes its cached value; a change that does not touch
  `oidc_user_id_claim` never calls this.

  Returns `:ok`. Best-effort and non-fatal: a re-read failure leaves the cache in
  a state that a subsequent request will lazily repopulate.
  """
  @spec invalidate_oidc_claim_cache() :: :ok
  defdelegate invalidate_oidc_claim_cache(), to: Nebu.Matrix.OidcClaimCache, as: :refresh

  # ── Device management (device-management S4 — Admin UI per-user devices) ──────
  #
  # The Admin domain manages a user's devices through this facade only (ADR-020);
  # it must never reach into `Nebu.Matrix.DeviceKeyStore` / `Session.DeviceBinding`
  # directly. The underlying user-scoped operations live in those internal modules.

  @doc """
  Lists a user's registered devices for the Admin UI (S4 AC1). Each map carries
  `"device_id"`, and (when present) `"display_name"`, `"last_seen_ts"`,
  `"last_seen_ip"`, `"created_ts"`. Sourced from the durable `devices` registry,
  so a keyless device still appears. Read-path: never raises.
  """
  @spec list_user_devices(String.t()) :: [map()]
  defdelegate list_user_devices(user_id), to: Nebu.Matrix.DeviceKeyStore, as: :list_devices

  @doc """
  Aggregate over `devices` active since `since_ms` (epoch millis) that have a non-empty `last_seen_ip`:
  `{:ok, %{devices: n, users: u, addresses: a}}` (counts only, never an address) or `{:error, reason}`
  (statement timeout, repo down, ...). Used by `Nebu.Workers.ClientIPCheckWorker` (story
  client-ip-misconfiguration-warnings). Never raises.
  """
  @spec device_address_spread(integer()) ::
          {:ok, %{devices: non_neg_integer(), users: non_neg_integer(), addresses: non_neg_integer()}} | {:error, term()}
  defdelegate device_address_spread(since_ms), to: Nebu.Matrix.DeviceKeyStore, as: :address_spread

  @doc """
  Renames a device's display name, scoped to the OWNING `user_id` (S4 AC2). Returns
  `:ok` when exactly that user's device row was updated, `:error` for an unknown /
  foreign device (no IDOR — the Admin UI maps `:error` to a flash, never to another
  user's device).
  """
  @spec rename_user_device(String.t(), String.t(), String.t() | nil) :: :ok | :error
  defdelegate rename_user_device(user_id, device_id, display_name),
    to: Nebu.Matrix.DeviceKeyStore,
    as: :rename_device

  @doc """
  Revokes a user's device (S4 AC3): ends every session of the device and removes all its
  persisted state (identity row + device/one-time/fallback keys) in ONE atomic teardown
  (`end_device_session/2`, story oauth-legacy-coexistence C12): the `devices` row is locked, every
  `matrix_sessions` row of the device (legacy AND OAuth) and the device tables are deleted in one
  transaction, then the bound raw-JWT credentials are killed (a binding is deleted only after its
  denylist write was confirmed, C13) and the per-device legacy `sessions` / `sync_tokens` rows are removed.
  User-scoped (never another user's device — no IDOR), idempotent (revoking an absent device is a no-op).
  Unlike the Matrix self-delete path there is no caller credential to preserve — an admin acts on
  another user's device, so EVERY token is revoked.

  `:ok` or `{:error, :unavailable}` (the teardown failed; nothing was ended, the Admin UI shows an error).
  """
  @spec delete_user_device(String.t(), String.t()) :: :ok | {:error, :unavailable}
  def delete_user_device(user_id, device_id)
      when is_binary(user_id) and is_binary(device_id) do
    end_device_session(user_id, device_id)
  end

  @doc """
  The atomic device teardown (story oauth-legacy-coexistence, C12; delegates to
  `Nebu.Matrix.OAuthSession.end_device_session/2`, the function behind `/oauth2/revoke`): locks the
  `devices` row (`FOR UPDATE`, the lock issuance and rotation take; lock order devices ->
  matrix_sessions), deletes EVERY `matrix_sessions` row of `(user_id, device_id)` (any `auth_api`) and the
  device tables in ONE transaction, then — best effort, after the commit — the JWT kill-switch and the
  per-device legacy session rows. A concurrent OAuth rotation therefore cannot leave a working token
  behind a deleted device. The web layer (`DELETE /devices`, `/delete_devices`) and the Admin UI reach
  it only through this function (ADR-020). `:ok | {:error, :unavailable}`; never raises.
  """
  @spec end_device_session(String.t(), String.t()) :: :ok | {:error, :unavailable}
  def end_device_session(user_id, device_id) when is_binary(user_id) and is_binary(device_id) do
    Nebu.Matrix.OAuthSession.end_device_session(user_id, device_id)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # ── Account management (epic oauth-broker, story oauth-account-management, A1) ────────────
  #
  # The OAuth domain's account page (`Nebu.OAuth.Account`) reaches the Matrix-owned `users`,
  # `profiles`, `devices` and `uia_sessions` ONLY through these functions (ADR-020). All are
  # error-aware (`{:error, :unavailable}` for a database problem, never an empty result) and never
  # raise; the implementation is `Nebu.Matrix.AccountManagement` (private to this domain).

  @doc """
  The Matrix user of verified IdP `claims` at the account-page callback (A7): the id is derived
  EXACTLY like the login (`UserId.from_claims/2` with the configured `server_name`), then an
  error-aware `is_active` read. NO provisioning (the page manages existing accounts) and never the
  fail-closed `active?/1`.

  `{:ok, %{user_id:, auth_time:}}` (`auth_time` = the id_token's `auth_time` claim ONLY, `iat` is not a
  substitute; `nil` when absent), `{:error, :unknown_user}` (no `users` row), `{:error, :deactivated}` or
  `{:error, :unavailable}` (database error).
  """
  @spec account_identity(map()) ::
          {:ok, %{user_id: String.t(), auth_time: integer() | nil}}
          | {:error, :unknown_user | :deactivated | :unavailable}
  def account_identity(claims) when is_map(claims), do: Nebu.Matrix.AccountManagement.identity(claims)

  @doc """
  The devices of `user_id` for the account page (A12): one map per `devices` row with `device_id`,
  `display_name`, `last_seen_ts` / `created_at` (epoch milliseconds), `last_seen_ip`, and the
  `auth_api` / `client_id` of the device's newest live session (`nil` when it has none), sorted by
  `last_seen_ts DESC NULLS LAST, device_id`, bounded at 5000 rows. Legacy and OAuth devices alike.
  ERROR-AWARE, unlike `list_user_devices/1`: `{:error, :unavailable}` instead of `[]`.
  """
  @spec account_devices(String.t()) :: {:ok, [map()]} | {:error, :unavailable}
  def account_devices(user_id) when is_binary(user_id), do: Nebu.Matrix.AccountManagement.devices(user_id)

  @doc """
  User id, display name and activity of the account-page user (A5, A8): `{:ok, %{user_id:,
  display_name:}}`, `{:error, :deactivated}`, `{:error, :not_found}` (no `users` row) or
  `{:error, :unavailable}`.
  """
  @spec account_profile(String.t()) ::
          {:ok, %{user_id: String.t(), display_name: String.t() | nil}}
          | {:error, :not_found | :deactivated | :unavailable}
  def account_profile(user_id) when is_binary(user_id), do: Nebu.Matrix.AccountManagement.profile(user_id)

  @doc """
  Who holds ONE device id of `user_id` (story oauth-authorize-freshness, FR11; the consent page and the Allow
  check): `{:ok, :none}` when there is no `devices` row and no live session row, `{:ok, %{display_name:,
  last_seen_ts:, auth_api:, client_id:}}` otherwise (`last_seen_ts` in epoch milliseconds; `auth_api` /
  `client_id` of the device's NEWEST LIVE `matrix_sessions` row, `nil` when it has none, `client_id` also
  `nil` for a legacy session) or `{:error, :unavailable}` (database error: never "no holder").
  The one-row variant of `account_devices/1`; never raises.
  """
  @spec oauth_device_holder(String.t(), String.t()) ::
          {:ok, :none | %{display_name: String.t() | nil, last_seen_ts: integer() | nil, auth_api: String.t() | nil, client_id: String.t() | nil}}
          | {:error, :unavailable}
  def oauth_device_holder(user_id, device_id) when is_binary(user_id) and is_binary(device_id) do
    Nebu.Matrix.AccountManagement.device_holder(user_id, device_id)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc """
  The user's PENDING cross-signing reset requests (A16): `m.oauth` UIA sessions (`op =
  "cross_signing_reset"`) that are unexpired, not consumed and not yet approved, newest first, at most
  20, each `%{session_id:, device_id:, device_display_name:, requested_at:, expires_at:, keys_fingerprint:}`
  (unix seconds; `keys_fingerprint` = the first 8 hex characters of the hash of the keys the request is bound to; `device_id` is the REQUESTING device). `{:error, :unavailable}` on a database problem.
  """
  @spec cross_signing_reset_requests(String.t()) :: {:ok, [map()]} | {:error, :unavailable}
  def cross_signing_reset_requests(user_id) when is_binary(user_id),
    do: Nebu.Matrix.AccountManagement.cross_signing_reset_requests(user_id)

  @doc """
  Approves ONE pending cross-signing reset request of `user_id` (A15/A16): ONE atomic conditional
  UPDATE (`stage_complete = TRUE`, `expires_at = LEAST(expires_at, now + 600 s)`) that matches only an
  unexpired, unconsumed, not yet approved `cross_signing_reset` session of THIS user. `:ok`,
  `{:error, :not_found}` (unknown / foreign / expired / consumed / already approved / another op) or
  `{:error, :unavailable}`. Of two parallel approvals exactly one returns `:ok`.
  """
  @spec approve_cross_signing_reset(String.t(), String.t()) :: :ok | {:error, :not_found | :unavailable}
  def approve_cross_signing_reset(user_id, session_id) when is_binary(user_id) and is_binary(session_id),
    do: Nebu.Matrix.AccountManagement.approve_cross_signing_reset(user_id, session_id)

  @doc """
  Declines a pending cross-signing reset request (`consumed = TRUE`; the client's next attempt gets a
  NEW challenge). Same conditions and results as `approve_cross_signing_reset/2`, without the
  "not yet approved" condition.
  """
  @spec decline_cross_signing_reset(String.t(), String.t()) :: :ok | {:error, :not_found | :unavailable}
  def decline_cross_signing_reset(user_id, session_id) when is_binary(user_id) and is_binary(session_id),
    do: Nebu.Matrix.AccountManagement.decline_cross_signing_reset(user_id, session_id)

  @doc """
  Deletes expired UIA sessions (the periodic `Nebu.Workers.OAuthFlowPurgeWorker`, A23): delegates to
  `Nebu.Matrix.Uia.cleanup_expired/0` (expired rows only, so the legacy UIA behaviour is unchanged).
  Returns the number of deleted rows (0 when the store cannot be written).
  """
  @spec purge_expired_uia_sessions() :: non_neg_integer()
  def purge_expired_uia_sessions, do: Nebu.Matrix.Uia.cleanup_expired()

  # The dispatcher reads the acting identity from the request-context map
  # (Nebu.Matrix.RequestMetadata). In-process callers (HTTP/Admin) pass a minimal
  # context map carrying the trusted identity — same shape as Nebu.Matrix.Http.stream/1.
  defp actor_stream(actor_id) do
    %{http_request_headers: %{"x-user-id" => actor_id, "x-system-role" => "instance_admin"}}
  end

  # not_found → {:error, :not_found} so the Admin UI can render a "Room not found"
  # flash; everything else is a generic {:error, message}.
  defp map_room_error(%Nebu.Matrix.Error{status: status, message: message}) do
    if status == Nebu.Matrix.Status.not_found() do
      {:error, :not_found}
    else
      {:error, message}
    end
  end
end
