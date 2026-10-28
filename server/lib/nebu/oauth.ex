defmodule Nebu.OAuth do
  @moduledoc """
  Public API of the OAuth domain (ADR-020 / ADR-033): Nebu as OAuth 2.0 authorization server
  (broker model O2) in front of the corporate IdP.

  Other domains (`Nebu.Admin`, `Nebu.Web`) call ONLY this module; the submodules
  (`Nebu.OAuth.Config`, `Nebu.OAuth.ClientStore`, `Nebu.OAuth.Registration`, `Nebu.OAuth.Metadata`,
  `Nebu.OAuth.Http`) are private to the domain. The one exception is the HTTP edge:
  `Nebu.Web.Router` forwards `GET /_matrix/client/v1/auth_metadata` and `POST /oauth2/register` to
  `Nebu.OAuth.Http`, exactly like it forwards the public Matrix routes to the Matrix domain's public
  HTTP module.
  There are two HTTP-edge forwarders: the router itself, and `Nebu.Web.Plugs.OAuthDiscovery`, which
  serves the `auth_issuer` / unstable `auth_metadata` discovery paths and hands them to
  `Nebu.OAuth.Http` while OAuth is enabled (it reads the switch only through `config/0` above).

  Story oauth-metadata-dcr-admin-approval covers: metadata discovery, Dynamic Client Registration
  and the admin approval of registrations. Story oauth-authorize-idp-delegation-code adds
  `GET /oauth2/authorize` (router -> `Nebu.OAuth.Http`), the IdP delegation and the Nebu
  authorization codes. Story oauth-token-endpoint (story 3) adds `POST /oauth2/token`
  (`Nebu.OAuth.Token`: authorization_code + refresh_token grants, `Nebu.OAuth.TokenRequest`),
  Nebu-signed ES256 id_tokens (`Nebu.OAuth.IdToken`, keys in `Nebu.OAuth.SigningKeyStore`),
  `GET /oauth2/jwks` and `GET /.well-known/openid-configuration`. The revocation endpoint followed in
  story 4 (resolved: every advertised endpoint exists since then): `POST /oauth2/revoke` (`Nebu.OAuth.Revoke`, RFC 7009, story oauth-token-revocation-logout),
  which is exempt from the kill switch (it can only delete sessions).

  ## Matrix -> OAuth entry points (ADR-020, story 2 D22)

  The IdP leg returns through the SHARED, IdP-registered Matrix callback
  `/_matrix/client/v3/login/sso/redirect/oidc` (owned by the Matrix domain). That callback calls
  ONLY `oauth_idp_state?/1` (pure prefix check of the `state`) and, when it is true,
  `handle_idp_callback/1`. In the other direction the OAuth domain reaches the IdP only through
  `Nebu.Matrix.idp_authorize_location/2`, `idp_complete_login/4` and `provision_login_user/1`.

  For story 3 (token endpoint): `consume_authorization_code/1` (atomic single use with reuse
  detection) and, for the periodic `Nebu.Workers.OAuthFlowPurgeWorker`,
  `purge_expired_flow_state/0`.

  ## Matrix -> OAuth: legacy SSO confirmation (story legacy-sso-redirect-confirmation, G3-3)

  Besides `oauth_aware?/0` (below) the Matrix domain asks this domain exactly three more things for the
  confirmation page of the legacy SSO login: `trusted_redirect_url?/2` (is a redirect URL on the OAuth issuer's origin or at or below the registered
  redirect URI of an APPROVED client: no confirmation needed), `parse_form_post/1` (the shared,
  hardened form-body parser) and `check_fetch_metadata/2` (the shared fetch-metadata rules). The Matrix domain
  never names a `Nebu.OAuth.*` submodule.

  ## Matrix -> OAuth: is OAuth offered? (story oauth-legacy-coexistence, C1)

  `oauth_aware?/0` is the ONLY question the Matrix domain asks this domain for the OAuth-aware surface (the OAuth-aware flags of
  `GET /login`, the SSO `action` parameter and, since story oauth-versions-switch, the `GET /_matrix/client/versions` list, v1.1-v1.15 while offered): true iff OAuth is offered, i.e. exactly while
  `GET /_matrix/client/v1/auth_metadata` answers `200` (the shared predicate
  `Nebu.OAuth.Config.live_state/0`). Option `bounded: true` (only `GET /_matrix/client/versions`, the load-balancer
  health check): a 500 ms bound on the `server_config` read and a throttled warning, see `Nebu.OAuth.Config.live_state/1`.

  ## Consent (story oauth-authorize-freshness, P3)

  A successful IdP login no longer mints a code: `Nebu.OAuth.Authorize` persists a consent row and
  redirects to `GET /oauth2/consent`; `Nebu.OAuth.Consent` (router -> `Nebu.OAuth.Http`, action `:consent`)
  mints the code only after the user's Allow. The Matrix domain is asked ONE more thing for it:
  `Nebu.Matrix.oauth_device_holder/2` (who holds the requested device id).

  ## Account management (story oauth-account-management, story 6)

  `Nebu.OAuth.Account` (the `/account` page, `Nebu.OAuth.Http` action `:account`) serves the account
  page; its sign-in rides on the shared IdP callback with the state tag `o2.acct.`
  (`handle_idp_callback/1` dispatches it). The Matrix domain asks this domain ONE thing for the
  `m.oauth` UIA stage of `POST /keys/device_signing/upload`: `cross_signing_reset_url/0`. The
  periodic purge also calls `purge_expired_account_state/0`. The page reaches Matrix-owned data only
  through the `Nebu.Matrix` facade (`account_identity/1`, `account_devices/1`, `account_profile/1`,
  `cross_signing_reset_requests/1`, `approve_cross_signing_reset/2`, `decline_cross_signing_reset/2`,
  `end_device_session/2`, `idp_authorize_location/2`, `idp_complete_login/4`).

  ## OAuth -> Matrix for sessions (story 3, T1)

  OAuth sessions are rows of the Matrix-owned `matrix_sessions` table (`auth_api = 'oauth'`). The
  token endpoint reaches them ONLY through the `Nebu.Matrix` facade: `oauth_issue_session/1`,
  `oauth_resolve_refresh_token/1`, `oauth_refresh_session/4`, `oauth_revoke_device_session/2`,
  `oauth_revoke_sessions_for_code/1` and (story 4) `oauth_revoke_token/1`. No file of this domain names a Matrix-internal module.
  """

  alias Nebu.OAuth.{AccountStore, AuthzStore, ClientStore, CodeStore, ConsentStore}

  @doc """
  True when `state` is an OAuth-broker IdP-leg state (`"o2."` prefix, D2) — also a malformed one,
  so it is never handled by the legacy SSO path. Pure, `false` for non-binaries.
  """
  @spec oauth_idp_state?(term()) :: boolean()
  def oauth_idp_state?("o2." <> _), do: true
  def oauth_idp_state?(_state), do: false

  @doc """
  Completes an OAuth-broker flow at the shared IdP callback (`conn.query_params` fetched). A state
  tagged `o2.acct.` belongs to the account-management page (story oauth-account-management, A6) and
  is handed to `Nebu.OAuth.Account` FIRST: it consumes the login request, verifies the browser
  binding, completes the IdP login and starts the account session. Every other `o2.` state
  (`Nebu.OAuth.Authorize`, UNCHANGED: an account state can never match its anchored state regex and
  a story-2 state can never start with `o2.acct.`, base64url has no `.`) consumes the authorization
  request, verifies the binding, completes the IdP login and redirects to the client with a Nebu
  authorization code (or an RFC 6749 error / an HTML error page).
  """
  @spec handle_idp_callback(Plug.Conn.t()) :: Plug.Conn.t()
  def handle_idp_callback(%Plug.Conn{query_params: %{"state" => "o2.acct." <> _}} = conn),
    do: Nebu.OAuth.Account.handle_idp_callback(conn)

  def handle_idp_callback(conn), do: Nebu.OAuth.Authorize.handle_idp_callback(conn)

  @doc """
  Consumes a Nebu authorization code exactly once (D17, for the story-3 token endpoint):
  `{:ok, row}` (atom keys = every `oauth_codes` column, `idp_rt_enc` still encrypted),
  `{:error, {:reused, row}}` for an already used code (story 3 revokes the session derived from
  it, by the `oauth_code_hash` stored on the session, T8), `{:error, :invalid}` for an unknown / expired / non-binary
  code, `{:error, :storage}` when the database is unavailable. Cluster safe (one atomic UPDATE).
  """
  @spec consume_authorization_code(term()) :: {:ok, map()} | {:error, :invalid | :storage | {:reused, map()}}
  def consume_authorization_code(code), do: CodeStore.consume(code)

  @doc """
  Purges expired flow state: authorization requests and consent requests (story
  oauth-authorize-freshness, FR6) past `expires_at`, codes more than 24 h past `expires_at` (batched,
  AC9/AC11). `{:ok, %{authz_requests: n, codes: m, consents: k}}` or `{:error, reason}`.
  """
  @spec purge_expired_flow_state() ::
          {:ok, %{authz_requests: non_neg_integer(), codes: non_neg_integer(), consents: non_neg_integer()}} | {:error, term()}
  def purge_expired_flow_state do
    with {:ok, requests} <- AuthzStore.purge_expired(),
         {:ok, consents} <- ConsentStore.purge_expired(),
         {:ok, codes} <- CodeStore.purge_expired() do
      {:ok, %{authz_requests: requests, codes: codes, consents: consents}}
    end
  end

  @doc """
  Purges the expired state of the account-management page (story oauth-account-management, A23):
  expired login requests and expired (idle or absolute) browser sessions, in batches. Called by the
  periodic `Nebu.Workers.OAuthFlowPurgeWorker` next to `purge_expired_flow_state/0` (whose return shape is
  unchanged). `{:ok, %{login_requests: n, sessions: m}}` or `{:error, reason}`.
  """
  @spec purge_expired_account_state() ::
          {:ok, %{login_requests: non_neg_integer(), sessions: non_neg_integer()}} | {:error, term()}
  def purge_expired_account_state, do: AccountStore.purge_expired()

  @doc """
  The URL of the `m.oauth` UIA stage of `POST /_matrix/client/v3/keys/device_signing/upload` (story
  oauth-account-management, A14), the ONLY thing the Matrix domain asks this domain for the stage:
  `{:ok, "<issuer>/account?action=org.matrix.cross_signing_reset"}` while the account page is live (the
  SAME predicate as `auth_metadata` 200 / `oauth_aware?/0`, so the URL is byte-equal to the metadata's
  `account_management_uri` plus the action and always https), `:unavailable` otherwise (OAuth off,
  invalid issuer, unreadable config, any failure: never a challenge that points at a dead page).
  Never raises.
  """
  @spec cross_signing_reset_url() :: {:ok, String.t()} | :unavailable
  def cross_signing_reset_url do
    case Nebu.OAuth.Config.live_state() do
      {:live, issuer} -> {:ok, issuer <> "/account?action=org.matrix.cross_signing_reset"}
      _ -> :unavailable
    end
  rescue
    _ -> :unavailable
  catch
    :exit, _ -> :unavailable
  end

  @doc """
  True when OAuth is OFFERED (story oauth-legacy-coexistence, C1/C2): the config state is `:enabled`
  and the issuer is valid — exactly the condition under which `GET /_matrix/client/v1/auth_metadata`
  answers `200` (the SAME predicate as `Nebu.OAuth.Config.live_state/0`'s `{:live, _}`, evaluated per
  call on top of the per-node config cache, at most `NEBU_OAUTH_CONFIG_CACHE_MS` stale, HY1). The Matrix domain (`GET /login` OAuth-aware flags, the SSO `action` parameter)
  asks ONLY this function (ADR-020), never `Nebu.OAuth.Config` / `Metadata`. `:disabled`, an invalid
  issuer, an unreadable `server_config` and any exception are `false` (fail closed). Never raises.
  """
  @spec oauth_aware?() :: boolean()
  def oauth_aware?, do: oauth_aware?([])

  @doc """
  `oauth_aware?/0` with options: `bounded: true` gives the `server_config` read a 500 ms bound and throttles
  its warning (ONLY `GET /_matrix/client/versions`, the load-balancer health check, story
  oauth-versions-switch review cycle 1); see `Nebu.OAuth.Config.live_state/1`. Fail closed, never raises.
  """
  @spec oauth_aware?(keyword()) :: boolean()
  def oauth_aware?(opts) when is_list(opts) do
    match?({:live, _}, Nebu.OAuth.Config.live_state(opts))
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc "`%{enabled: boolean, issuer_url: binary | nil}` — see `Nebu.OAuth.Config`."
  @spec config() :: Nebu.OAuth.Config.t()
  defdelegate config(), to: Nebu.OAuth.Config, as: :get

  @doc """
  Validates an issuer URL with the ONE function the runtime uses (`Nebu.OAuth.Metadata.normalize_issuer/1`): absolute `https`, a host,
  no userinfo, no query, no fragment, an empty path (a single trailing `/` is stripped): `{:ok, normalized}` or `:error`. The Admin UI
  switch form (story admin-oauth-switch) validates its input with this function, never with a copy.
  """
  @spec normalize_issuer(term()) :: {:ok, String.t()} | :error
  defdelegate normalize_issuer(url), to: Nebu.OAuth.Metadata

  @doc """
  The effective TTL of the per-node cache of the switch state in milliseconds (`NEBU_OAUTH_CONFIG_CACHE_MS`, `0` = off): how long
  another node can still serve the old state after an Admin UI change (ADR-033 HY2). For the Admin UI's propagation notes.
  """
  @spec config_cache_ms() :: 0..5000
  defdelegate config_cache_ms(), to: Nebu.OAuth.Config, as: :cache_ms

  @doc """
  Persists the OAuth switch for the Admin UI (story admin-oauth-switch, ADR-033 "Admin UI switch"): `changes` is
  `%{"oauth_enabled" => "true" | "false", "oauth_issuer_url" => binary}`. Both `server_config` upserts and the caller's `:audit`
  function (0-arity, `:ok | {:error, reason}`) run in ONE transaction, so a change is unaudited ONLY through `:unaudited_ok` (the
  Admin UI sets it for a result OFF whose issuer stays the same or is cleared): after a failed audit the change is then applied WITHOUT the
  audit row (the kill switch is never blocked by an unwritable audit table), with one value-free ERROR log. After a commit this node's switch cache is dropped.
  `{:ok, %{audited: boolean}}`, `{:error, {:audit, reason}}` (nothing persisted), `{:error, :invalid_issuer | :invalid_changes |
  :audit_required}` or `{:error, reason}`. See `Nebu.OAuth.SwitchStore`.
  """
  @spec save_switch(map(), keyword()) :: {:ok, %{audited: boolean()}} | {:error, term()}
  defdelegate save_switch(changes, opts), to: Nebu.OAuth.SwitchStore, as: :save

  @doc """
  One page (50 per page, newest first) of the pending client registrations for the admin approval
  list, with the real total (the list is never silently truncated):
  `{:ok, %{registrations:, total:, page:, page_size:, total_pages:}}`, or `{:error, reason}` when
  the database is unavailable (never an empty list for an error). See
  `Nebu.OAuth.ClientStore.get_pending_registrations/1`.
  """
  @spec pending_registrations(term()) :: {:ok, map()} | {:error, term()}
  def pending_registrations(page \\ 1), do: ClientStore.get_pending_registrations(page)

  @doc """
  Purges `pending` registrations older than the configured TTL (`oauth_pending_ttl_days`, default
  30 days); `approved`/`rejected` rows are never touched. Called by the periodic
  `Nebu.Workers.OAuthPendingPurgeWorker`. `{:ok, deleted_count}` or `{:error, reason}`.
  """
  @spec purge_expired_pending() :: {:ok, non_neg_integer()} | {:error, term()}
  def purge_expired_pending, do: ClientStore.purge_expired_pending()

  @doc "Registrations per page of `pending_registrations/1`."
  @spec page_size() :: pos_integer()
  def page_size, do: ClientStore.page_size()

  @doc """
  Read-only preview of the admin's bulk removal of pending registrations (story
  oauth-dcr-abuse-hardening, AH9): `{:ok, %{count:, rows:}}` — the real number of matching pending
  rows inside the `as_of` snapshot and the first 20, newest first — or `{:error,
  {:invalid_criteria, reason}}` / `{:error, reason}`. `criteria` is `%{host:, match: :exact |
  :domain, older_than_days:}`, see `Nebu.OAuth.ClientStore.normalize_criteria/1`.
  """
  @spec bulk_remove_preview(map(), DateTime.t()) :: {:ok, map()} | {:error, term()}
  def bulk_remove_preview(criteria, as_of), do: ClientStore.bulk_preview(criteria, as_of)

  @doc """
  The database clock, the time base of the bulk-removal snapshot (`created_at` is a database timestamp):
  `{:ok, DateTime}` or `{:error, reason}`. The admin takes the preview's `as_of` from here.
  """
  @spec bulk_remove_snapshot() :: {:ok, DateTime.t()} | {:error, term()}
  def bulk_remove_snapshot, do: ClientStore.db_now()

  @doc """
  Age of a snapshot in microseconds on the database clock (negative = in the future), for the
  "preview expired" window check: `{:ok, integer}` or `{:error, reason}`.
  """
  @spec bulk_remove_snapshot_age_us(DateTime.t()) :: {:ok, integer()} | {:error, term()}
  def bulk_remove_snapshot_age_us(as_of), do: ClientStore.snapshot_age_us(as_of)

  @doc """
  The effective criteria of a bulk removal after normalisation (what is really swept): `{:ok, %{host:
  exact host | nil, domain: registrable domain | nil, days: n | nil}}` or `{:error, {:invalid_criteria,
  reason}}`. Pure, no query. Used for the audit row.
  """
  @spec bulk_remove_criteria(map()) :: {:ok, map()} | {:error, term()}
  def bulk_remove_criteria(criteria), do: ClientStore.normalize_criteria(criteria)

  @doc """
  Deletes the PENDING registrations matching `criteria` and created at or before `as_of` (the
  preview snapshot), at most 500 per call. `{:ok, %{removed:, remaining:, client_ids:}}`, `{:error,
  {:invalid_criteria, reason}}`, `{:error, {:audit, reason}}` (the removal was rolled back) or
  `{:error, reason}`. Option `:audit` (1-arity fun over the removed client ids, same transaction),
  see `Nebu.OAuth.ClientStore.bulk_delete_pending/3`. Approved / rejected registrations are never
  deleted.
  """
  @spec bulk_remove_pending(map(), DateTime.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def bulk_remove_pending(criteria, as_of, opts \\ []), do: ClientStore.bulk_delete_pending(criteria, as_of, opts)

  @doc """
  Host classification for the approval page (the admin domain never reaches `Nebu.OAuth.PublicSuffix`,
  ADR-020): `%{domain:, suffix:, public_suffix?:, shared_hosting?:, valid?:}` for a DNS host (the
  registrable domain, whether the host IS a public suffix, whether it is below a multi-tenant hosting
  suffix such as `github.io`, and whether it is a valid registration host), or `nil` for anything
  that is not a host with at least two labels. Pure, never raises.
  """
  @spec host_info(term()) :: map() | nil
  def host_info(host) when is_binary(host) do
    case Nebu.OAuth.PublicSuffix.classify(host) do
      {:ok, %{domain: domain, suffix: suffix, kind: kind, public_suffix?: ps?}} ->
        %{
          domain: domain,
          suffix: suffix,
          public_suffix?: ps?,
          shared_hosting?: kind == :private and not ps?,
          valid?: Nebu.OAuth.Registration.valid_host?(host)
        }

      {:error, _} ->
        nil
    end
  end

  def host_info(_other), do: nil

  @doc "One registration by `client_id` (any status) or `nil` — e.g. to name the client in a flash message."
  @spec registration(String.t()) :: map() | nil
  def registration(client_id), do: ClientStore.get_by_client_id(client_id)

  @doc """
  Approves a pending registration on behalf of `admin_user_id`. `:ok`, or
  `{:error, :not_pending}` when the client is unknown or already decided.

  Option `:audit` (0-arity fun returning `:ok | {:error, reason}`) runs in the SAME database
  transaction as the decision; when it fails the decision is rolled back and
  `{:error, {:audit, reason}}` is returned — a decision is never unaudited. The approval also
  erases the first registrant's IP / user agent.
  """
  @spec approve_registration(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def approve_registration(client_id, admin_user_id, opts \\ []),
    do: ClientStore.approve(client_id, admin_user_id, opts)

  @doc "Rejects a pending registration (the registration itself is kept). Same contract as `approve_registration/3`."
  @spec reject_registration(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def reject_registration(client_id, admin_user_id, opts \\ []),
    do: ClientStore.reject(client_id, admin_user_id, opts)

  # ── approved / revoked clients, revocation (story oauth-client-revocation) ───────────────

  @doc """
  One page (50, newest approval first) of the APPROVED clients for the admin list, each with its live session
  count: `{:ok, %{clients: [map], total:, page:, page_size:, total_pages:}}`. A client map has `client_id`,
  `metadata`, `application_type`, `client_host`, `approved_by`, `approved_at`, `last_used_at` and `sessions`
  (devices with a live session, read through the Matrix facade; `:unknown` when that read failed: the admin
  shows `?`, never `0`). `{:error, reason}` when the clients could not be read.
  """
  @spec approved_clients(term()) :: {:ok, map()} | {:error, term()}
  def approved_clients(page \\ 1) do
    with {:ok, %{clients: clients} = paging} <- ClientStore.get_approved_clients(page) do
      counts = Nebu.Matrix.oauth_client_session_counts(Enum.map(clients, & &1.client_id))

      clients =
        Enum.map(clients, fn client ->
          sessions =
            case counts do
              {:ok, by_client} -> Map.get(by_client, client.client_id, 0)
              {:error, _} -> :unknown
            end

          Map.put(client, :sessions, sessions)
        end)

      {:ok, %{paging | clients: clients}}
    end
  end

  @doc "How many revoked clients stated this `client_host`: `{:ok, n}` or `{:error, reason}` (the approve confirm page warns, L-3)."
  @spec revoked_count_for_host(String.t() | nil) :: {:ok, non_neg_integer()} | {:error, term()}
  def revoked_count_for_host(host), do: ClientStore.revoked_count_for_host(host)

  @doc "One page of the REVOKED clients (newest revocation first), same shape as `approved_clients/1` without sessions."
  @spec revoked_clients(term()) :: {:ok, map()} | {:error, term()}
  def revoked_clients(page \\ 1), do: ClientStore.get_revoked_clients(page)

  @doc """
  The number of devices with a live session of the client (the revoke confirmation page): `{:ok, n}` or
  `{:error, :unavailable}` (shown as `?`).
  """
  @spec client_session_count(String.t()) :: {:ok, non_neg_integer()} | {:error, :unavailable}
  def client_session_count(client_id) when is_binary(client_id) do
    case Nebu.Matrix.oauth_client_session_counts([client_id]) do
      {:ok, counts} -> {:ok, Map.get(counts, client_id, 0)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Revokes an APPROVED client (decisions CR1-CR5): status `revoked`, every session, device and E2EE device key of
  the client, its unused codes, authorize and consent requests are gone in ONE transaction, the `:audit` function
  (1-arity over the torn-down `{user_id, device_id}` pairs, runs in the same transaction) decides the commit.
  `actor` is the attribution (`revoked_by`); options `:reason` (already normalised, <= 500 characters) and
  `:audit`. `{:ok, %{devices: n}}`, `{:error, :not_approved}` (unknown, pending, rejected or already revoked: nothing
  changed), `{:error, {:audit, reason}}` or `{:error, reason}` (rolled back). A revocation is final for the
  client's metadata: identical metadata never becomes pending or approved again. See
  `Nebu.OAuth.ClientStore.revoke/3`.
  """
  @spec revoke_client(String.t(), String.t(), keyword()) :: {:ok, %{devices: non_neg_integer()}} | {:error, term()}
  def revoke_client(client_id, actor, opts \\ []), do: ClientStore.revoke(client_id, actor, opts)

  @doc """
  One step of the operator's two-phase id_token signing-key rotation (story oauth-hardening-hygiene, HY12):
  publish a `next` key, or (after 900 s) promote it. Used by `Nebu.Release.rotate_oauth_signing_key/0`, which
  supplies the REQUIRED `:audit` hook (a call without it raises `KeyError`). See `Nebu.OAuth.SigningKeyStore.rotate/1`.
  """
  defdelegate rotate_signing_key(opts), to: Nebu.OAuth.SigningKeyStore, as: :rotate

  @doc """
  Emergency replacement of an undecryptable active signing key (HY13); see
  `Nebu.OAuth.SigningKeyStore.replace_emergency/1`. Used by `Nebu.Release.replace_oauth_signing_key/1`.
  """
  defdelegate replace_signing_key(opts), to: Nebu.OAuth.SigningKeyStore, as: :replace_emergency

  # Control / format (bidi, zero-width) / private-use / surrogate / line+paragraph separator characters are
  # stripped (same class as the client_name rule of Nebu.OAuth.Registration): a NUL would make the jsonb audit
  # insert fail, bidi overrides could disguise the reason later.
  @hostile_reason_re ~r/[\p{Cc}\p{Cf}\p{Co}\p{Cs}\p{Zl}\p{Zp}]/u
  @max_reason 500

  @doc """
  Normalises a free-text admin / operator reason (reject, revoke): hostile characters stripped, trimmed, at most
  500 characters; `nil` for anything that is not valid text or ends up empty. The ONE copy (admin controllers and
  `Nebu.Release`).
  """
  @spec normalize_reason(term()) :: String.t() | nil
  def normalize_reason(reason) when is_binary(reason) do
    if String.valid?(reason) do
      case reason |> String.replace(@hostile_reason_re, "") |> String.trim() |> String.slice(0, @max_reason) do
        "" -> nil
        cleaned -> cleaned
      end
    end
  end

  def normalize_reason(_), do: nil

  @doc """
  The request-origin fetch-metadata rules of the browser forms WITHOUT an Origin comparison (`:strict`: all four
  headers present exactly once; `:lenient`: absent allowed), for the admin controllers (story
  oauth-client-revocation, SO2; ADR-020: the admin domain reaches the OAuth domain only through this module). `:ok`
  or `{:refused, [header_name]}`. See `Nebu.OAuth.BrowserPost.check_fetch_metadata/2`.
  """
  @spec check_fetch_metadata(Plug.Conn.t(), :strict | :lenient) :: :ok | {:refused, [String.t()]}
  defdelegate check_fetch_metadata(conn, level), to: Nebu.OAuth.BrowserPost

  @doc """
  The strict rules with the click proof for browsers that never send `Sec-Fetch-User` (Safari): `:ok`, `:unproven` or
  `{:refused, [header_name]}`. See `Nebu.OAuth.BrowserPost` (story safari-fetch-metadata-compat).
  """
  @spec check_fetch_metadata(Plug.Conn.t(), :strict | :lenient, term()) :: :ok | :unproven | {:refused, [String.t()]}
  defdelegate check_fetch_metadata(conn, level, params), to: Nebu.OAuth.BrowserPost

  @doc """
  True when the legacy SSO login may hand a loginToken to `raw_redirect_url` WITHOUT a confirmation page because
  of this domain (story legacy-sso-redirect-confirmation, G3-3, D4 source 3 / D6, security review SEC #1).
  `origin` is the normalized origin of the URL (`https://host[:port]`, lower case, default port dropped, built by
  the caller from the same parse). Two sources, independent of `oauth_enabled`:

    * the ORIGIN of the configured `oauth_issuer_url` (by default Nebu's own host, but an administrator can set any https host through the Admin UI switch, which therefore asks for an acknowledgement and an audit row; no database read);
    * an `approved` client's REGISTERED redirect URI, not its origin: the raw URL must EQUAL a registered `https`
      `redirect_uri` or extend it at a path boundary (the next character is `/`, `?` or `#`, or the registered URI
      itself ends with `/`); the path is compared case-sensitively and a URL with dot segments or an encoded dot /
      slash / backslash in its path never matches. Another path on the same origin is NOT trusted: an approval of
      `https://storage.example/<bucket>/cb` must not make `https://storage.example/<attacker-bucket>/x` a silent
      loginToken sink. `pending`, `rejected` and `revoked` clients never count; an approve or a revocation takes
      effect immediately (no cache).

  ONE bounded query (500 ms) on the jsonb array `redirect_uris`, narrowed by host. Any error, timeout or exception
  is `false` plus ONE value-free WARNING (`OAuth: trusted redirect origin lookup failed`, never the origin or the
  URL: fail closed, the caller shows the confirmation page); non-binary or malformed input is `false`. Never raises.
  """
  @spec trusted_redirect_url?(term(), term()) :: boolean()
  def trusted_redirect_url?(origin, raw_redirect_url) when is_binary(origin) and is_binary(raw_redirect_url) do
    with {:ok, canonical, host} <- canonical_https_origin(origin),
         {:ok, ^canonical, raw_rest} <- split_https_url(raw_redirect_url) do
      issuer_origin?(canonical) or approved_client_uri?(canonical, host, raw_rest)
    else
      _ -> false
    end
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  def trusted_redirect_url?(_origin, _raw_redirect_url), do: false

  @origin_re ~r/\Ahttps:\/\/([a-z0-9][a-z0-9.\-]*)(?::([0-9]{1,5}))?\z/

  # `https://host[:port]` only (lower-cased, default port dropped) -> `{:ok, origin, host}`.
  defp canonical_https_origin(origin) do
    case Regex.run(@origin_re, String.downcase(origin)) do
      [_, host | port] ->
        case port |> List.first() |> parse_port() do
          :error -> :error
          nil -> {:ok, "https://" <> host, host}
          n -> {:ok, "https://" <> host <> ":" <> Integer.to_string(n), host}
        end

      _ ->
        :error
    end
  end

  defp parse_port(nil), do: nil
  defp parse_port(""), do: nil

  defp parse_port(port) do
    case Integer.parse(port) do
      {443, ""} -> nil
      {n, ""} when n in 1..65_535 -> n
      _ -> :error
    end
  end

  # An https URL -> `{:ok, normalized origin, rest}` (`rest` = everything after the authority, as received).
  defp split_https_url(url) do
    case Regex.run(~r/\Ahttps:\/\/([^\/?#]*)(.*)\z/is, url) do
      [_, authority, rest] ->
        with {:ok, canonical, _host} <- canonical_https_origin("https://" <> authority), do: {:ok, canonical, rest}

      _ ->
        :error
    end
  end

  # The origin of the configured issuer, also while OAuth is OFF; an unreadable server_config contributes nothing.
  defp issuer_origin?(canonical) do
    with {:ok, normalized} <- Nebu.OAuth.Config.configured_issuer(bounded: true),
         {:ok, issuer_origin, _host} <- canonical_https_origin(normalized) do
      issuer_origin == canonical
    else
      _ -> false
    end
  end

  defp approved_client_uri?(canonical, host, raw_rest) do
    if climbs?(raw_rest) do
      false
    else
      case ClientStore.approved_redirect_uris(host) do
        {:ok, uris} -> Enum.any?(uris, &registered_uri_trusts?(&1, canonical, raw_rest))
        :error -> false
      end
    end
  end

  # A registered https URI trusts the raw URL when both have the same origin and the raw rest equals the registered
  # rest or extends it at a path boundary.
  defp registered_uri_trusts?(uri, canonical, raw_rest) when is_binary(uri) do
    case split_https_url(uri) do
      {:ok, ^canonical, registered_rest} -> extends_at_boundary?(raw_rest, registered_rest)
      _ -> false
    end
  end

  defp registered_uri_trusts?(_uri, _canonical, _raw_rest), do: false

  defp extends_at_boundary?(rest, rest), do: true

  defp extends_at_boundary?(rest, registered) do
    size = byte_size(registered)

    if byte_size(rest) > size and binary_part(rest, 0, size) == registered do
      tail = binary_part(rest, size, byte_size(rest) - size)
      String.ends_with?(registered, "/") or String.starts_with?(tail, ["/", "?", "#"])
    else
      false
    end
  end

  # dot segments, an encoded dot / slash / backslash, a matrix parameter (`;`, as in `..;/`: some servers and proxies
  # strip it before resolving the dots) or a double encoding (`%25`, as in `%252e%252e`) in the PATH could climb out of
  # the registered path. Fail closed: such a URL is "not listed" and the user sees the confirmation page (X-4).
  defp climbs?(rest) do
    path = rest |> String.split(["?", "#"], parts: 2) |> hd()

    Regex.match?(~r/%(2e|2f|5c|25)/i, path) or String.contains?(path, ";") or
      Enum.any?(String.split(path, "/"), &(&1 in [".", ".."]))
  end

  @doc """
  Parses the `application/x-www-form-urlencoded` body of a browser form POST with the hardened OAuth rules (a
  non-empty query string, another content type, a body over 16 KiB, malformed encoding, a duplicated parameter or a
  control character is an error; empty values are dropped). The raw body is read exactly once here
  (`Nebu.Web.Plugs.JsonBody` skips the form routes). `{:ok, conn, params}` or `{:error, conn, status, description}`.
  Used by the legacy SSO confirmation page (story legacy-sso-redirect-confirmation, D9); ADR-020: the Matrix domain
  never names the form-post module itself.
  """
  @spec parse_form_post(Plug.Conn.t()) ::
          {:ok, Plug.Conn.t(), %{String.t() => String.t()}} | {:error, Plug.Conn.t(), pos_integer(), String.t()}
  defdelegate parse_form_post(conn), to: Nebu.OAuth.FormPost, as: :parse
end
