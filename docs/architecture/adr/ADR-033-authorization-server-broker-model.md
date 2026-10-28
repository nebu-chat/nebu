# ADR-033: Nebu ist Authorization Server (Broker, Model O2)

## Status

Accepted - 2026-10-09

Builds on: ADR-018 (inline SQL, no domain model), ADR-020 (feature domains as module namespaces,
cluster safety), ADR-022 (OIDC configured exclusively via the Bootstrap Wizard).
Source: `_bmad-output/planning-artifacts/oauth-broker-spec.md` (Matrix spec v1.18, OAuth 2.0 API).

## Context

Matrix clients of spec v1.15+ (Element Web, the Matrix Dart SDK / FluffyChat) discover an OAuth 2.0
authorization server through `GET /_matrix/client/v1/auth_metadata`, register themselves with
Dynamic Client Registration (RFC 7591) and obtain Matrix access and refresh tokens from the
authorization server's token endpoint. Until now Nebu was only a resource server: it proxied the
corporate IdP's `/.well-known/openid-configuration` as `auth_metadata` and accepted IdP-issued JWTs
as Bearer tokens. That sends clients straight to the IdP (which would have to know and approve every
Matrix client, scope and redirect URI), cannot express Matrix scopes, and cannot support Dynamic
Client Registration (corporate IdPs do not offer open registration).

## Decision

Nebu becomes an OAuth 2.0 **Authorization Server** in front of the corporate IdP: the
**broker model "O2"** of the spec.

- **Roles.** Nebu is Authorization Server AND Resource Server. The corporate IdP (Identity Provider)
  is an identity provider only: it authenticates the human, nothing else. Clients never talk to the
  IdP; the `issuer` in Nebu's metadata is Nebu's own public URL.
- **Token issuance.** Only Nebu issues Matrix access and refresh tokens. IdP-issued JWTs are NOT
  accepted as Bearer tokens on the OAuth path; the existing IdP-JWT Bearer path stays as a
  **legacy** exception for sessions created through the old login (see Implications).
- **Scope management.** All Matrix scopes are Nebu-internal. The IdP sees a single, Nebu-owned
  client (the one OIDC client of ADR-022) and never a per-application client or a Matrix scope.
- **Dynamic Client Registration with admin approval.** Registration is open (RFC 7591) but EVERY
  registration starts `pending` and becomes usable only after an admin approved it in the Admin UI.
  Approval is per metadata hash: identical metadata resolves to one `oauth_clients` row. There is
  deliberately no auto-approve mode and no policy switch; an allowlist would be a separate decision.
  `approved` and `rejected` registrations are never deleted (spec: a server MUST NOT delete a
  registration with an active session); rejecting only sets the status. `pending` registrations
  never have a session and ARE purged after a TTL (see "Pending registrations" below).
- **https-for-all-URLs.** Every URL Nebu advertises in its OAuth metadata (issuer and all
  endpoints) must be `https`. This is a Nebu rule, stricter than RFC 6749 and RFC 8414, which
  require https only for the issuer / where the specification demands transport security. A
  non-https issuer configuration makes the metadata endpoint answer `404 M_UNRECOGNIZED` instead of
  advertising http URLs.
- **Switch.** `oauth_enabled` (`server_config`, default `false`). While disabled, the stable
  metadata (`v1/auth_metadata`) and registration endpoints answer `404 M_UNRECOGNIZED` (Matrix
  error shape): never 503 and never an IdP passthrough, because the Dart SDK distinguishes exactly
  this case. (`auth_issuer` and the unstable `auth_metadata` are different: see "Discovery: one
  issuer".) The config read is three-state (enabled / disabled / unknown, security review N-4).
- **Domain.** The code lives in the new namespace `Nebu.OAuth` (public API: the `Nebu.OAuth`
  module, ADR-020); the Admin UI calls it only through that module. SQL is inline in
  `Nebu.OAuth.ClientStore` (ADR-018); registration dedup and approval are atomic in the database
  (`ON CONFLICT (metadata_hash) DO NOTHING`, `UPDATE ... WHERE status = 'pending'`), no
  application-level locks (ADR-020).

## Consequences

- `auth_metadata` is Nebu's own RFC 8414 document; the passthrough logic of the stable path is
  replaced. The unstable MSC2965 paths and `auth_issuer` follow the `oauth_enabled` switch, see
  "Discovery: one issuer" below.
- Secrets of the OAuth endpoints (`code`, `code_verifier`, `device_code`, `refresh_token`,
  `client_secret`) are redacted from request payload logs from day one.
- New attack surface: an open, unauthenticated registration endpoint. It is rate limited in three
  families (own buckets for junk requests, a loose per-IP bucket for valid requests and a strict
  per-IP + global bucket for requests that would insert a NEW row; see "Registration rate
  limits"), validates all URIs strictly and registers only `pending` clients; pending rows are
  capped (globally and per `client_uri` host) and purged after a TTL (see "Pending
  registrations").

## Pending registrations (decision after code-review cycle 0, 2026-10-09)

`POST /oauth2/register` is unauthenticated, so anyone can create `pending` rows (about 60 KB each
at the metadata limits) and fill the approval list. The per-IP/global rate limit lives in a
node-local ETS table and is abuse control only. The following bounds are therefore part of the
design:

- **TTL purge.** A `pending` registration older than `oauth_pending_ttl_days` (`server_config`,
  default **30**) is deleted. `approved` and `rejected` rows are NEVER purged.
  - *Mechanism:* the Oban cron job `Nebu.Workers.OAuthPendingPurgeWorker` (hourly, own queue
    `oauth_cleanup`, limit 1), the repo's established periodic-job pattern (`Oban.Plugins.Cron`
    enqueues from the Oban leader only). Correctness does not depend on that: the work is
    `Nebu.OAuth.ClientStore.purge_expired_pending/1`, a batched (1000 rows, at most 20 batches per
    run) `DELETE ... WHERE status = 'pending' AND client_id IN (SELECT ... FOR UPDATE SKIP LOCKED)`.
    Concurrent runs on several nodes split the rows; a row that is being approved right now is
    skipped, and `status = 'pending'` is re-checked after the row lock, so a decided row is never
    deleted. No advisory lock, no node-local state (ADR-020).
  - *Database guard:* migration 000040 grants `DELETE` to the runtime role but enables AND forces
    row level security on `oauth_clients` (the table owner would otherwise bypass it, as in the
    single-role dev setup): the `SELECT` and `UPDATE` policies are open, the `INSERT` policy
    admits only pending rows (see "Database invariants"), the only `DELETE` policy is
    `USING (status = 'pending')`. Because RLS judges the current row, a trigger refuses any
    `UPDATE` that turns a decided row back to `pending` (which would make it deletable).
    The runtime role therefore cannot delete an approved or rejected registration even if
    application code is wrong or SQL is injected. (The migration owner / superuser, e.g. for
    operator clean-up and the e2e hygiene hook, bypasses RLS as usual.)
- **Cap.** At most `oauth_pending_cap` (`server_config`, default **5000**) `pending` rows. A
  registration of NEW metadata above the cap is refused with `503 temporarily_unavailable`
  (OAuth error shape, `Retry-After: 3600`); a re-registration of known metadata (a dedup hit, in
  any status) still returns the existing `client_id`. The check is part of the INSERT statement
  (`INSERT ... SELECT ... WHERE (SELECT count(*) ... status = 'pending') < cap`). READ COMMITTED
  does not serialise concurrent counts, so N concurrently executing registrations can overshoot
  the cap by at most N-1 (bounded by the pool size per node and the rate limits); this is
  accepted for a soft abuse cap, instead of locking a table on a public endpoint.
- **Per-host cap** (security review F-1b; rewritten by story oauth-dcr-abuse-hardening, AH1, AH2). At
  most `oauth_pending_host_cap` (`server_config`, default **20**) `pending` rows per
  (registrable domain of the `client_uri` host, client source): `oauth_clients.client_domain`
  (public-suffix aware, subdomain rotation does not help) AND `oauth_clients.source_key` (the
  resolved client address, IPv4 /32 or IPv6 /64, hashed). So an attacker filling its OWN slots for a
  real host no longer blocks the real client, which registers from another source; a source is additionally
  limited to 100 pending rows over all domains (built-in), and the global cap above stays. Same
  answer as the global caps (`503 temporarily_unavailable` + `Retry-After`), same INSERT-time
  check, dedup hits bypass every cap; nothing is evicted. The key name `oauth_pending_host_cap`
  and its range are unchanged, its meaning changed. Without a verified `NEBU_TRUSTED_PROXY_CIDRS`
  all clients share one source (AH12). See "DCR and flow-state abuse hardening".
- **Config keys.** `oauth_pending_ttl_days` and `oauth_pending_cap` are added to the
  `config_update_mutable` allowlist in migration 000040 (all earlier keys kept), as is
  `oauth_pending_host_cap` (below). Invalid,
  non-positive or absurd values (TTL above 3650 days, cap above 10 million) fall back to the
  defaults, never to "unlimited".
- **Approval list.** The admin list is paginated (50 per page, `?page=N`, newest first like the
  other admin tables) and shows the real total plus "N more pending on later pages"; it is never
  silently truncated. A flood below the cap can therefore no longer hide older legitimate
  registrations (they are reachable on later pages), and the cap and the purge bound the flood.

### Database invariants (security review F-3)

The database, not only the application, enforces the lifecycle of `oauth_clients` (migration
000040):

- The INSERT policy admits only `status = 'pending'` rows with `approved_by`, `approved_at`,
  `rejected_by` and `rejected_at` NULL: every registration starts pending, the runtime role cannot
  insert an already approved row. A decision is only ever an UPDATE of a pending row, and that
  UPDATE is final (see the guard trigger below).
- The guard trigger fires on every UPDATE and refuses any change of `client_id`, `metadata`,
  `metadata_hash`, `application_type`, `token_endpoint_auth_method` and `client_host`: approved
  metadata (redirect URIs) can never be rewritten without a new registration and a new approval.
- A decision is FINAL in the database (security review N-3): once `OLD.status <> 'pending'` the
  trigger refuses every change of `status`, `approved_by`, `approved_at`, `rejected_by` and
  `rejected_at`: no rejected-to-approved (which would bypass the admin gate), no
  approved-to-rejected, no re-attribution, no return to pending. Still allowed on a decided row:
  `last_used_at` and the NULLing of `created_from_ip` / `user_agent`.
- A CHECK (`oauth_clients_decision_check`) ties `approved` / `rejected` rows to their `*_by` /
  `*_at` columns and keeps pending rows free of them; the two decisions are mutually exclusive.
- Fixtures that need a decided row insert it pending and then UPDATE it (as the app does).
- **Update (story oauth-client-revocation, migration 000046):** "a decision is final" gains exactly ONE
  exception: `approved -> revoked` (CR1-CR3 below). A `revoked` row keeps its `approved_*` attribution,
  is never deleted (the DELETE policy stays pending-only) and keeps its metadata hash occupied; every
  other change of a decided row (also `pending -> revoked`) stays a `check_violation`. See "Client
  revocation and same-origin hardening (story oauth-client-revocation)".

### Retention of first-registrant data (security review F-7)

`created_from_ip` and `user_agent` of the first registrant are stored only for abuse triage of
PENDING registrations. The approve and reject UPDATE set both columns to NULL, so decided rows
(which live forever) carry no personal data. They are not shown anywhere, and pending rows are
purged after the TTL anyway.

### Registration rate limits (security review F-1)

Three bucket families in the node-local ETS limiter of `Nebu.Web.Plugs.RateLimit`:

- **Invalid** (own buckets, F-1 remainder): 600/hour per IP and 5000/hour globally, charged ONLY
  by junk: an unparsable, oversize or invalid body, or any request while OAuth is disabled. When
  exhausted the junk request is answered `429` instead of its 4xx. Junk therefore never spends the
  budget a dedup hit depends on (before cycle 5 junk and dedup hits shared the global loose
  bucket, so a junk flood could block every OAuth login).
- **Loose**, charged by every VALID request: 600/hour per IP and NO global bucket. It is the ONLY
  budget a dedup hit pays (a dedup hit is one indexed SELECT).
- **Strict**, charged only by a request that would INSERT a new row (valid metadata unknown by
  hash): 50/hour per IP, 500/hour globally.

Order: enabled?, body, validation (junk is charged to the invalid buckets), loose limit, hash
lookup; a dedup hit is answered with the existing `client_id`; a new registration pays the strict
limit and then the pending caps (global and per host). Spec section 4 has clients register on
EVERY flow, so a known client must not compete with new registrations for the strict budget.
Remaining weakness, recorded as a gate item and resolved in the server by story
oauth-trusted-proxy-client-ip: the "IP" is `Nebu.Web.ClientIP.get/1`, the directly connected peer
unless that peer is listed in `NEBU_TRUSTED_PROXY_CIDRS`. Without that configuration (the default) it
still is the direct peer, so behind nginx every client shares the per-IP buckets (see "Trusted-proxy
client IP (phase 2, story oauth-trusted-proxy-client-ip)" and "Gate items"). Junk and valid traffic no
longer share a bucket, so that weakness can only throttle a client's own traffic class.

## Discovery: one issuer (decision Phil 2026-10-07, spec section 14 #7; security review F-2)

Once OAuth is enabled, discovery must name ONE issuer, Nebu's:

- `GET /_matrix/client/v1/auth_issuer` and `.../unstable/org.matrix.msc2965/auth_issuer` answer
  `{"issuer": "<Nebu issuer>"}`, the same issuer as the metadata document. The unstable
  `.../org.matrix.msc2965/auth_metadata` is an alias of the stable document, served by
  `Nebu.OAuth.Http` (no IdP field, no made-up IdP `registration_endpoint`/`revocation_endpoint`).
  An enabled switch with an invalid issuer URL answers `404 M_UNRECOGNIZED` (fail closed).
- While OAuth is DISABLED (default) these three paths keep the pre-broker IdP passthrough
  (`Nebu.Matrix.HttpPublic`). This is the DECISION (Phil, 2026-10-09; spec section 14 #7 amended):
  Nebu's issuer is advertised only while OAuth is enabled, and these paths do not become a 404
  while it is disabled, because that would break the existing Element/FluffyChat login of every
  deployment that has not enabled OAuth. With OAuth off there is no Nebu authorization server and
  no approval gate, so the passthrough bypasses nothing. The stable `v1/auth_metadata` is Nebu's
  own document and stays a 404 while disabled. Routing: `Nebu.Web.Plugs.OAuthDiscovery`.
- **Three-state config (security review N-4).** `Nebu.OAuth.Config.get/0` reports `state:
  :enabled | :disabled | :unknown`. The passthrough is taken ONLY on a positively read `:disabled`.
  When `server_config` cannot be read (`:unknown`, e.g. a DB timeout while OAuth is enabled) the
  three discovery paths answer `503 {"errcode":"M_UNKNOWN"}` with `Cache-Control: no-store`, no
  `issuer` and no passthrough, so a transient error can never advertise the IdP issuer next to
  Nebu's. 503 rather than 404 because the state is transient: clients and caches must retry, not
  conclude "OAuth unsupported". The OAuth endpoints themselves stay fail closed (404) on
  `:unknown`. "No repository process" (unit runs, early boot) counts as `:disabled`.
- **Accepted risk (legacy bypass).** While OAuth is enabled, a client that ignores the Nebu
  discovery paths and talks to the IdP directly (the legacy `m.login.sso` login, or the IdP's own
  well-known) is not subject to the DCR admin approval until the legacy login is shut down. The
  approval gate protects the OAuth path only; this is the explicit cost of "legacy coexistence".

## Authorization endpoint, IdP delegation and codes (story 2)

Story `oauth-authorize-idp-delegation-code` (2026-10-10, oracle gate 2026-10-10) implements the
browser half of the authorization code grant: `GET /oauth2/authorize` (`Nebu.OAuth.Authorize`,
pure validation in `Nebu.OAuth.AuthorizeRequest` / `Nebu.OAuth.Scope`), the delegation to the IdP,
the IdP callback and the Nebu authorization code. `/oauth2/token` and `/oauth2/revoke` stayed
unrouted (404) until stories 3/4 (until story 4), so `oauth_enabled` had to stay false until then (resolved: all advertised endpoints exist since story 4; contract-tested in story 9). Decisions:

- **D1 Shared callback (deliberate deviation from spec section 3).** The IdP leg reuses the ONE IdP
  client and its FIXED, already registered redirect URI `/_matrix/client/v3/login/sso/redirect/oidc`.
  There is no `/oauth2/callback` route: it would only work if operators registered a second redirect
  URI at their corporate IdP, which is exactly the reconfiguration the broker model avoids.
  `SsoLogin.callback/1` branches on the state tag before any legacy logic runs.
- **D2 State tag.** IdP-leg state = `o2.` + 43 base64url chars (32 random bytes). Legacy states are
  32 hex chars and cannot collide; every `o2.` state (also a malformed one) goes to the OAuth branch.
  Stored only as `state_hash` = SHA-256 hex.
- **D3 Cluster-safe flow state.** NOT the node-local `SsoStore` (ETS, best-effort replication): the
  IdP PKCE verifier (SecretBox-encrypted), the IdP nonce, the client request and a browser-binding
  hash live in `oauth_authz_requests` (migration 000041, TTL 10 min), consumed by ONE atomic
  `DELETE ... RETURNING ..., (expires_at > now()) AS live`. Any node can complete a flow; a node
  restart loses nothing.
- **D4 Browser binding (RFC 9700 4.7, login CSRF).** The authorize 302 sets a per-flow cookie
  `nebu_oa_<16 hex of state_hash>` (on an https request `__Host-nebu_oa_<16 hex>` with `Path=/; Secure`, HY9; 32 random bytes, `HttpOnly; SameSite=Lax`, on http path = the callback (on https `Path=/`),
  `Max-Age=600`, `Secure` on https); only its SHA-256 is stored. The callback requires it (constant
  time compare) and clears it; a missing/mismatching cookie gives the `invalid_state` page and the
  request stays consumed. Assumption: authorize and callback are served on the same host.
- **D5 No consent screen.** Admin approval of the registration is the consent gate and the IdP
  always asks for an interactive login (oracle gate accepted; follow-up note for review). The
  premise "interactive login every time" is enforced as far as the IdP allows: the OAuth leg always
  sends `max_age=0` next to `prompt=login` (also when `prompt=create` replaces it; Kassandra F-2),
  because `prompt` alone is advisory. The `auth_time` freshness check at the callback and a consent
  screen remain gate item (i) in `follow-ups.md`. **Superseded by FR1** (story
  oauth-authorize-freshness): a consent screen is now shown on every authorization.
- **D6 `api:*` required (Nebu policy).** Missing `<prefix>api:*` => `invalid_scope`. The granted
  Matrix scope is always `<prefix>api:* <prefix>device:<id>` (plus `openid`, D23).
- **D7 Unknown scope tokens ignored (RFC 6749 3.3), mixed prefixes rejected (Nebu policy).** Tokens
  outside the RFC 6749 charset make the request `invalid_scope`; stable and unstable Matrix tokens
  may not be mixed (the granted scope echoes the request's prefix).
- **D8 Device-id validator.** 1..255 bytes of `%x21 / %x23-5B / %x5D-7E` (own validator, not the
  looser Matrix helper); exactly one `device:` token (occurrences counted); no minimum length.
- **D9 Device reuse.** `devices` is keyed `(user_id, device_id)`: nothing to reject in story 2.
  Story 3 revokes earlier tokens of a reused device atomically at token issuance.
- **D10 `response_mode` (corrected by the oracle gate).** `query` and `fragment` are accepted for
  EVERY redirect URI and an explicit value is always honoured (matrix-js-sdk hard-codes `query` and
  Element Web registers an https URI). Absent => `fragment` for https, `query` otherwise. Anything
  else => `invalid_request` in the default mode.
- **D11 `prompt`.** Toward the IdP Nebu keeps `prompt=login`; client `prompt=create` is forwarded
  only when the IdP lists `create` in `prompt_values_supported`. `prompt=none` => `login_required`
  error redirect without contacting the IdP; `none` combined with another value =>
  `invalid_request`. `prompt_values_supported` is NOT advertised in Nebu's metadata.
- **D12 Unknown parameters ignored** (`action`, `login_hint`, `max_age`, `ui_locales`, `claims`,
  `request`, `request_uri`); none is forwarded to the IdP. The client `nonce` is validated and
  stored, never forwarded (D23).
- **D13 Duplicates.** The raw query string is parsed (not `conn.query_params`): a duplicated or
  array-shaped `client_id` / `redirect_uri` or a malformed percent-encoding => HTML page; any other
  duplicated parameter => `invalid_request` redirect.
- **D14 `state`.** Optional, <= 2048 bytes, valid UTF-8, no control characters; a violation =>
  `invalid_request` without echoing it.
- **D15 `iss` (RFC 9207).** Every authorization response carries `iss` = the normalized issuer
  (byte-equal to the metadata `issuer`); the metadata advertises
  `authorization_response_iss_parameter_supported: true`. Live only when OAuth is enabled AND the
  issuer normalizes, else `404 M_UNRECOGNIZED` (no DB access, no rate-limit token).
- **D16 Code format.** 256-bit random, base64url; only `code_hash` (SHA-256 hex) is stored in
  `oauth_codes`, TTL 60 s, bound to client, exact redirect URI, PKCE challenge, device, user, scope,
  response mode. The SecretBox-encrypted IdP refresh token and `auth_time` live in the code row
  (story oauth-authorize-freshness: `auth_time` is the raw `auth_time` claim or NULL, never `iat` (FR4);
  the row is minted at the user's Allow, not at the callback, FR1).
- **D17 Single use and reuse detection.** `UPDATE oauth_codes SET used_at = now() WHERE code_hash
  = $1 AND used_at IS NULL AND expires_at > now() RETURNING ...` (exactly one winner across the
  cluster); on 0 rows one SELECT distinguishes a reuse (`{:reused, row}`, story 3 revokes the
  derived session by `(user_id, device_id, client_id)`) from an unknown/expired code. Used and
  expired codes are kept 24 h after expiry, then purged (`Nebu.Workers.OAuthFlowPurgeWorker`, every
  10 min). The database enforces it: a guard trigger only allows `used_at` NULL -> NOT NULL, RLS
  refuses deleting a code earlier.
- **D18 Provisioning at the callback.** The same provisioning as legacy `POST /login`
  (`Nebu.Matrix.provision_login_user/1`: user row, profile, personal room / auto-join with
  `is_new`); a deactivated user => `access_denied`. Device registration and session creation are
  story 3, which must re-check `is_active` at the token endpoint.
- **D19 Abuse bounds.** Node-local buckets `{"oauth_authorize", ip}` and `{"oauth_callback", ip}`
  (600/h per IP each, charged before any DB access; 429 page), and at most 10 000 live
  `oauth_authz_requests` rows (soft cap inside the INSERT; above => `temporarily_unavailable`; since
  story oauth-dcr-abuse-hardening additionally at most 300 live rows per source, AH10, so one client
  cannot fill the 10 000). No global bucket. The trusted-proxy gate item 1 applies to these buckets too.
- **D20 No audit rows, minimal logging.** Like Matrix logins, authorize/callback outcomes are not
  written to `audit_log`. INFO logs carry only `client_id`, the outcome and (after the callback)
  `user_id` / `device_id`. `RequestLogger` logs the query strings of `/oauth2/authorize` and of the
  callback with parameter names only.
- **D21 No stubs** for `/oauth2/token` / `/oauth2/revoke`.
- **D22 Module boundaries (ADR-020).** The IdP leg stays in the Matrix domain (it owns the IdP
  client): `Nebu.Matrix.idp_authorize_location/2`, `idp_complete_login/4`, `provision_login_user/1`
  wrap the SAME `SsoLogin` builder / completion the legacy login uses. The callback calls only
  `Nebu.OAuth.oauth_idp_state?/1` and `Nebu.OAuth.handle_idp_callback/1`.
- **D23 `openid` and the client `nonce` (story-3 obligation).** matrix-js-sdk 41.3.0 requests
  `openid` plus the unstable Matrix prefix, sends a `nonce` and validates an id_token in the token
  response. Story 2 keeps `openid` in the granted scope, stores `openid_requested` and the
  validated client `nonce` in `oauth_authz_requests` and `oauth_codes` (never sent to the IdP).
  **Story 3 MUST issue a Nebu-signed id_token (`iss` = Nebu issuer, `aud` = client_id, `nonce` =
  stored client nonce, `sub`) whenever `openid_requested` is true** (needs a Nebu signing key and a
  `jwks_uri` decision).

Accepted property (code review cycle 1): the callback consumes the authorization request (one
atomic DELETE) BEFORE it checks the browser-binding cookie. A third party who learns a live IdP-leg
`state` (it travels through the user's browser only) can therefore burn that one login attempt by
calling the callback without the cookie (the user has to start the login again); it cannot complete
it, because the binding check still fails. The alternative (check the binding before consuming)
would make the request row guessable-state-probeable and non-atomic, so this denial-of-one-login is
accepted. The 256-bit state makes guessing infeasible, and the per-IP callback bucket (D19) bounds
attempts.

Error handling: before the client and its redirect URI are trusted (unknown client, bad redirect
URI, pending/rejected client, unknown/expired/replayed IdP state) the answer is an accessible HTML
page (`Nebu.OAuth.Pages`, strict CSP, no script), never a redirect; after that every error is an
RFC 6749 4.1.2.1 redirect (`error`, fixed `error_description`, `state`, `iss`, never `errcode`), and
the callback takes the redirect target ONLY from the consumed request row (open-redirect safe).

## Token endpoint, sessions, refresh and id_token (story 3)

Story `oauth-token-endpoint` (2026-10-10, oracle gate 2026-10-10) turns the story-2 authorization
code into a Matrix session with Nebu as authorization server AND resource server: `POST
/oauth2/token` (`authorization_code` + `refresh_token`), Nebu-signed ES256 id_tokens, `GET
/oauth2/jwks` and `GET /.well-known/openid-configuration`. `/oauth2/revoke` stays unrouted (until story 4) (resolved: live since story 4),
so `oauth_enabled` stays false. Decisions (prefix `T`, so they never collide with story 2's D1-D23):

- **T1 Module boundaries (ADR-020).** OAuth domain: `Nebu.OAuth.Token` (orchestration, responses),
  `Nebu.OAuth.TokenRequest` (pure parsing, PKCE, scope narrowing), `Nebu.OAuth.IdToken` (pure claims
  + signing), `Nebu.OAuth.SigningKeyStore` (inline SQL). Sessions live in the Matrix-owned
  `matrix_sessions`, so all session SQL is Matrix domain (`Nebu.Matrix.OAuthSession`,
  `Nebu.Matrix.Session.OAuthSessionStore`), reached ONLY through five `Nebu.Matrix` facade functions
  (`oauth_issue_session/1`, `oauth_resolve_refresh_token/1`, `oauth_refresh_session/4`,
  `oauth_revoke_device_session/2`, `oauth_revoke_sessions_for_code/1`); a static test keeps
  `lib/nebu/oauth/*.ex` free of Matrix-internal module names.
- **T2 One table, an `auth_api` column (data model).** OAuth sessions are rows of `matrix_sessions`
  with `auth_api = 'oauth'` (legacy rows: `'legacy'`, the DEFAULT, rolling-deploy safe), plus
  `client_id` (FK `ON DELETE RESTRICT`: a registration with a session cannot be deleted), `scope`,
  `session_expires_at`, `oauth_code_hash` (migration 000042, named CHECKs). Same row model as legacy:
  one row per token pair, a session = all rows of `(user_id, device_id)`, at most one active row.
  Logout, device deletion, admin deactivation and the OidcPlug opaque path therefore work unchanged (OAuth logout and revocation: story 4).
- **T3 Two expiries.** OAuth rows: `expires_at` = ACCESS-token expiry
  (`LEAST(now() + ttl, session_expires_at)`), `session_expires_at` = the absolute session maximum
  (`now() + NEBU_MATRIX_SESSION_TTL_SECONDS` at code redemption, copied verbatim on every rotation,
  never extended). A refresh is allowed while `session_expires_at > now()`.
- **T4 Access-token TTL** `oauth_access_token_ttl_seconds` (server_config), 60..3600, default 900;
  tokens are 64 lowercase hex (opaque, no `.`), stored only as SHA-256 hashes.
- **T5 `oauth_idp_revalidation`** = `per_refresh` (default, also for unknown values: fail safe) or
  `off`. `per_refresh` redeems the stored SecretBox-encrypted IdP refresh token on EVERY Nebu
  refresh (`revalidate_with_idp/1` + `RefreshErrors`); `off` re-checks only `users.is_active`.
- **T6 Fail closed** when `per_refresh` and the code has no IdP refresh token: `invalid_grant` at
  the code grant + one WARNING naming the fix (`matrix_oidc_refresh_mode=offline` or
  `oauth_idp_revalidation=off`). Earlier detection at the IdP callback: follow-up (l).
- **T7 Device reuse (spec 5.1).** Issuance deletes EVERY earlier `matrix_sessions` row of the
  device (legacy and OAuth) in the same transaction as the insert; the device row and its E2EE keys
  are kept; raw IdP JWTs bound to the device are denylisted afterwards (S3 kill switch).
- **T8 Code reuse revocation, bound to proof (RFC 9700).** The session stores `oauth_code_hash`
  (copied on rotation), so a reused code revokes EXACTLY the derived session — but only when the
  reused presentation passes the same checks as a first redemption (client, byte-equal redirect URI,
  valid PKCE verifier). The reused code is ALWAYS `invalid_grant`.
- **T9 Consumption order.** The story-2 atomic consume marks the code used BEFORE the binding checks:
  a wrong verifier/redirect/client burns the code (accepted, same class as story 2).
- **T10 Refresh-Retry (legacy 0c semantics).** Rotation on every refresh; the old refresh token stays
  redeemable (PENDING, `grace_until IS NULL`) until the new access token authenticates a request or
  the new refresh token is redeemed (then CONSUMED); no time window. A pending token is served by
  rotating the device's active row again (lost-response retry), re-validated `FOR UPDATE`.
- **T11 Refresh-token reuse.** A CONSUMED refresh token of an alive session revokes every
  `auth_api = 'oauth'` row of the device (WARNING) and answers `invalid_grant`, independent of the
  presented `client_id`; unknown / expired / legacy tokens are `invalid_grant` without side effects.
- **T12 Client binding** of refresh tokens: another client's `client_id` => `invalid_grant`, no
  revocation.
- **T13 Scope on refresh.** Absent or empty `scope` = the granted scope; otherwise a set comparison
  with prefix-normalized Matrix tokens (stable == unstable): only `openid` may be dropped (persistent);
  anything else `invalid_scope`, session untouched.
- **T14 Scope echo.** The response `scope` is the stored granted string verbatim (request prefix).
- **T15 id_token when** `openid` is granted (code grant; refresh while still granted).
- **T16 id_token claims:** exactly `iss` (byte-equal to the metadata issuer), `sub` (Matrix user id),
  `aud` (client_id as a string), `iat`, `exp = iat + 300`, `auth_time`, `nonce` (code grant only,
  OIDC Core 12.2). No personal data, no `at_hash`/`azp`.
- **T17 Signing key: ES256, Nebu-generated, encrypted at rest.** `ES256` (P-256) is a code constant,
  never read from input or the stored row. Rejected alternatives: **HS256** (no shared secret can
  exist for public clients; a verifier could forge tokens), **RS256** (large keys, slow generation, no
  benefit), **EdDSA** (not universally supported by browser JOSE stacks), reusing the IdP's keys
  (Nebu cannot sign with them). `kid` = RFC 7638 thumbprint; the private JWK only as SecretBox
  ciphertext in `oauth_signing_keys`, the public JWK as `jsonb`; never logged.
- **T18 Key lifecycle, cluster-safe lazy generation.** At most ONE `active` row (partial UNIQUE
  index); `ensure_active_key/0` = SELECT, else generate + `INSERT ... ON CONFLICT DO NOTHING` + SELECT
  (single winner, no advisory lock, no node-local "active kid" state). Loading verifies the
  decrypted key against `kid` AND `public_jwk` (SecretBox has no associated data). Retirement is an
  UPDATE (guard trigger: key material immutable, no re-activation, `not_after` only raised); the JWKS
  (`jwks_uri` = `<issuer>/oauth2/jwks`) publishes the active key, a pre-published `next` key (HY11) and unexpired retired keys. Rotation tooling: HY12/HY13 (`Nebu.Release.rotate_oauth_signing_key/0`, `replace_oauth_signing_key(:emergency)`; two-phase
  rotation with a pre-published `next` key, story oauth-hardening-hygiene); runbook in 07-deployment.
- **T19 Error-aware `is_active`.** The token endpoint never uses the fail-closed
  `Nebu.Matrix.active?/1`: inactive => `invalid_grant` (+ revocation on refresh), DB error => 503.
- **T20 Error mapping (oracle C1).** 4xx = RFC 6749 5.2 `{"error", "error_description"}` with fixed
  text, never `errcode`; only DEFINITIVE outcomes are 4xx.
  Every 5xx (503 transient, 500 rescued exception) carries `Retry-After` and the body `{}` WITHOUT an `error` member.
  Rationale: oidc-client-ts turns ANY JSON with `error` into an `ErrorResponse`, which matrix-js-sdk treats as a logout (`TokenRefreshLogoutError`).
- **T21 Rate limits.** `{"oauth_token", ip}` 600/h per IP (code grant, junk; `429 too_many_requests`).
  A `grant_type=refresh_token` request is NEVER answered 429: its own bucket `{"oauth_token_refresh", ip}` (6000/h) answers 503 `{}` + `Retry-After`.
  Both are node-local abuse control; behind nginx they need the trusted-proxy gate (item 1).
- **T22 Kill switch.** Disabled / invalid issuer => `404` with the body `{"errcode":"M_UNRECOGNIZED"}` on
  `/oauth2/token`, `/oauth2/jwks` and `/.well-known/openid-configuration`: NO `error` member (review
  cycle 1), so an operator switching OAuth off does not turn refreshing oidc-client-ts clients into
  logouts (any JSON with `error` becomes an `ErrorResponse`; without it matrix-js-sdk sees a plain
  `Error` and keeps retrying). The stable `auth_metadata` endpoint and `/oauth2/register` keep their
  Matrix-shaped body with `error`.
  An unreadable config (`:unknown`) answers 503 `{}` + `Retry-After: 5` on token, JWKS and openid-configuration. (`/oauth2/revoke` is exempt, story 4 R13: it stays live while OAuth is disabled.)
- **T23 Request format.** POST, `application/x-www-form-urlencoded`, 16 KiB cap, raw body read once
  (JsonBody skips the path, the body is never logged); a query string, a duplicated parameter or a
  control character => `invalid_request`; an empty value = omitted (RFC 6749 3.1).
- **T24 Client authentication `none`.** `client_id` required; unknown/pending/rejected, a non-empty
  `client_secret` or `Authorization: Basic` => `401 invalid_client`; other `Authorization` schemes
  ignored; the registered `grant_types` must contain the grant (`unauthorized_client`).
- **T25 No IdP JWT for OAuth devices (spec 2).** Three layers: issuance denylists legacy JWT bindings
  of a reused device; `DeviceBinding.put/4` refuses to bind a legacy raw JWT to a device with an OAuth
  session; `OidcPlug` refuses a JWT whose binding points at an OAuth device (`401 M_UNKNOWN_TOKEN`).
  User-level raw-JWT access without an OAuth device stays the legacy exception (story 5) (C14: kept; follow-up u).
- **T26 Legacy login on an OAuth device = take-over.** Legacy `POST /login` with the `device_id` of an
  OAuth device deletes the device's OAuth rows first (cs.md "Relationship between access tokens and
  devices"), so a device is never served by both APIs.
- **T27 Legacy isolation.** `POST /refresh`, the `RefreshWorker` and the legacy store's refresh /
  extension functions act on `auth_api = 'legacy'` rows only; the OAuth store only on `'oauth'` rows;
  the pending-sibling consumption only within the same `auth_api`.
- **T28 IdP refresh-token race guard.** A genuine IdP token-endpoint rejection (`400`/`401`,
  `invalid_grant`) is NOT final only when the device's active row now carries a NEW IdP refresh-token
  ciphertext — proof that a concurrent refresh really redeemed the IdP token and stored the
  provider-rotated successor; the request is then served as a replay without a second IdP call. A
  changed access-token hash alone proves nothing (a skip itself rewrites it, which would let a token
  holder bypass `per_refresh` with overlapping refreshes: Kassandra F-1), and Nebu-side verdicts
  (`:deactivated`, `:no_oidc_refresh_token`, decrypt failures, other statuses) always revoke. Residual
  (follow-up n): two truly concurrent refreshes against a rotating IdP can still end in a false
  logout when the loser's rejection arrives before the winner committed. Rotation also takes the
  `devices` row lock the issuance upsert takes, so a re-login cannot interleave with a rotation.
  Edge case (INFO): when the IdP call succeeds (and the IdP rotates its refresh token) but the Nebu
  rotation then fails (database error, lost race exhausted), the provider-rotated IdP refresh token is
  lost: the stored ciphertext is now invalid at the IdP, so the next refresh of the SAME Nebu refresh
  token gets a confirmed IdP rejection and revokes the session (the client logs in again). The legacy
  path has the same limitation (the legacy path keeps its documented limitation).
  **Extended by FR15** (story oauth-authorize-freshness): the IdP leg now runs under a per-device lease,
  so two parallel refreshes no longer both call the IdP; T28 remains for an expired lease (a holder that
  stalled past its TTL).
- **T29 No audit rows, minimal logging.** INFO: grant type, client id, outcome, user/device after
  success; WARNING: reuse revocations, client mismatch, T6, IdP rejections (`RefreshErrors.describe/1`
  only). Never a token, code, verifier, id_token, IdP token, key material, redirect URI or scope
  value; the token response body is not captured by `RequestLogger`.
- **T30 Metadata truthfulness.** `auth_metadata` gains `jwks_uri` and
  `id_token_signing_alg_values_supported: ["ES256"]` (both required by matrix-js-sdk's
  `validateAuthMetadataAndKeys`); `oauth_clients.last_used_at` is touched at most once per hour.
- **T31 `/.well-known/openid-configuration` (oracle C7).** Nebu serves its OWN metadata document
  under the issuer (byte-identical to `auth_metadata`, never the IdP passthrough), because
  `OidcTokenRefresher` fetches `new URL(".well-known/openid-configuration", issuer)`.
  Issuer-path constraint: relative resolution drops the issuer's last path segment, so the Nebu issuer MUST have an empty path (a trailing `/` is stripped; any other path is rejected, 404 on every OAuth endpoint).
  The reference nginx templates must route `/oauth2/` and this path before `oauth_enabled` (follow-up (m)).
- **T32 CORS.** Token, JWKS and openid-configuration answer `Access-Control-Allow-Origin: *` and
  never `Access-Control-Allow-Credentials` (CORSPlug runs with `credentials: false` for exactly
  these three paths, also on preflights); preflights run no endpoint logic.
- **T33 `expires_in`** is computed from the same `now()` as the row's `expires_at`, so the server
  never rejects an access token before the advertised lifetime.

Deliberate deviations:

- **Proof-gated code-reuse revocation (oracle C10).** RFC 6749 4.1.2 says the server SHOULD revoke
  all tokens previously issued based on a reused code; Nebu revokes only when the reused
  presentation carries the valid PKCE verifier (and client / redirect URI). A presentation without
  the verifier cannot have produced tokens and must not let a third party log the user out. This
  weakens the SHOULD for reuses without the verifier — a deliberate deviation. Double-submit risk:
  a legitimate client that submits the same code twice concurrently presents a valid proof on the
  losing request, which may revoke the session the winner just received (accepted; invariant:
  exactly one 200, never a live session that no 200 handed out).
- **Legacy-to-legacy device reuse (oracle C8).** A legacy `/login` with the device id of an existing
  LEGACY device does not invalidate that device's earlier legacy tokens. This is a pre-existing spec
  deviation (cs.md "Relationship between access tokens and devices"), recorded in follow-ups.md and
  not changed by story 3 (story 5 may revisit); OAuth devices are taken over (T26).

## Token revocation and logout (story 4)

Story `oauth-token-revocation-logout` (2026-10-10, oracle gate 2026-10-10) makes the advertised
`revocation_endpoint` real and lets an OAuth session end cleanly: `POST /oauth2/revoke` (RFC 7009), OAuth-aware
`POST /_matrix/client/v3/logout`, the newly routed `POST /_matrix/client/v3/logout/all`, and the missing
session kill of the GDPR key erasure. Decisions (prefix `R`, so they never collide with story 2's D1-D23 or
story 3's T1-T33):

- **R1 Module boundaries (ADR-020).** OAuth domain: `Nebu.OAuth.Revoke` (HTTP orchestration) and `Nebu.OAuth.FormPost`
  (the form-POST plumbing extracted from `Nebu.OAuth.Token`, a move not a copy). Matrix domain:
  `Nebu.Matrix.OAuthSession` (`revoke_token/1`, `end_device_session/2`, `end_all_for_user/1`) and
  `Nebu.Matrix.Session.OAuthSessionStore`, reached only through the `Nebu.Matrix` facade functions `oauth_revoke_token/1`,
  `oauth_end_user_sessions/1` (and `end_all_user_devices/1` for `/logout/all`); `lib/nebu/oauth/*.ex` names no Matrix-internal module.
- **R2 What a revocation ends (Matrix logout semantics, device and keys).** A hit ends the device's OAuth session
  completely in ONE transaction: every `matrix_sessions` row of `(user_id, device_id)` (the IdP refresh-token ciphertext dies
  with the rows) and the `devices` row with `device_keys`, one-time and fallback keys; afterwards, best effort, the S3 JWT
  kill-switch (bindings are deleted only after every denylist write was confirmed; a failed write keeps them, and the ETS entry of the node stays) and the per-device legacy session rows. Contrast with T8 / T11 (unchanged): code-reuse and refresh-token-reuse
  revocations delete only the OAuth rows and keep the device (security reactions, not a user's logout).
- **R3 Token lookup.** Either token (access or refresh) in ANY state (active, expired access token, superseded, pending or
  consumed refresh token, expired session) in one statement over both indexed hash columns; `token_type_hint` is ignored.
- **R4 No client authentication.** `client_id` is optional, never looked up and only compared for the log line; a missing or wrong `client_id` still revokes: R4 conforms to the Matrix spec (SHOULD still revoke; the server MAY warn), which takes precedence over the RFC 7009 2.1 client binding. A leaked LEGACY token cannot be killed through `/oauth2/revoke` (R5, accepted).
- **R5 Unknown / malformed / legacy tokens** (not 64 lowercase hex, no `auth_api = 'oauth'` row) => `200 {}`, no side effect;
  a malformed value costs no DB access.
- **R6 Response shapes.** Success and "unknown token": `200 {}` with `Content-Type: application/json` (oracle O3: oidc-client-ts accepts
  it, a `text/*` type would make it throw). 4xx: RFC 6749 5.2 shape; every 5xx is `Retry-After` + `{}` (T20 contract kept).
- **R7 Error reachability.** Reachable: `400 invalid_request`, `413`, `405` (also HEAD), `429`, sub-path `404`, `503`/`500 {}`.
  `401 invalid_client` and `400 unsupported_token_type` are unreachable by design (no client is authenticated, both token types are supported).
- **R8 Request format = T23.** POST, form-encoded, 16 KiB, raw body read once (`JsonBody` skips the path); duplicates, control
  characters, a query string => `invalid_request`; the token is compared after form-decoding and never trimmed.
- **R9 Rate limit.** `{"oauth_revoke", ip}` 60/min, burst 600, charged after the parse and before any DB access; exhausted => `429`.
  Covered by the trusted-proxy gate (item 1).
- **R10 No oracle.** A revoked, unknown, malformed and legacy token are answered byte-identically; only a real token causes the DELETE.
- **R11 Atomicity (cluster safe).** One transaction: plain SELECT of the presented row, the `devices` row lock `FOR UPDATE` (the same
  lock issuance and rotation take; order devices -> matrix_sessions), a re-check after the lock (a T7 re-login may have replaced the
  session), DELETE of all rows of the device (a new statement, so a rotation that committed meanwhile is deleted too), device
  tables via a raising variant inside the transaction. Idempotent for the parallel access/refresh revocations of Element.
- **R12 IdP refresh token.** Deleted with the session; Nebu calls NO IdP revocation endpoint (the IdP is only an identity source,
  no outbound calls from an unauthenticated endpoint); follow-up (t).
- **R13 No kill switch for revoke (oracle O5).** `/oauth2/revoke` is exempt from the T22 kill switch: it stays LIVE while OAuth is disabled or the issuer is invalid (it can only delete; otherwise server sessions would survive a logout made while OAuth is off); only an unreadable config (`:unknown`) answers `503 {}` + `Retry-After: 5`, before any parse or rate-limit token.
- **R14 CORS = T32.** `/oauth2/revoke` joins the credentials-free CORS branch: ACAO `*` on EVERY status, preflights answered by CORSPlug.
- **R15 `POST /logout` with an OAuth access token** ends ONLY that device's session through the same function (R2), decided at
  authentication time (`OidcPlug` assigns `:auth_api`); a storage failure => `500 M_UNKNOWN`; an expired or superseded access token never reaches it (`401` + `soft_logout`).
- **R16 Legacy `POST /logout` (the recorded deviation) is RESOLVED by the bugfix legacy-logout-per-device (LL1-LL12):** it ends only the presented credential's device with the locked teardown, like R15; the `/logout` deviation no longer exists.
- **R17 `POST /logout/all` is routed now (both APIs).** It ends every OAuth session (with device and keys), then runs the legacy part, then tears down EVERY device of the user
  with its keys (oracle correction); cross-signing keys stay. `200 {}` only when every CHECKED part succeeded (OAuth part, the matrix_sessions deletes, the per-device teardown and the caller's raw-JWT denylist insert); a failed checked part => `500 M_UNKNOWN` while the others still ran. Best-effort parts, invisible to the status: the legacy core cleanup of `sessions`/`sync_tokens` (`invalidate_user_sessions`) and the kill-switch of other devices' bound raw JWTs (a failed denylist write keeps their bindings; they are effectively orphaned once the device is gone: noted by the delta review). Review cycle 1
  (Kassandra F-1/F-2): the device set is the union of the user's `devices` rows and `matrix_sessions` device ids, and each device gets the atomic, locked teardown of R11 (devices
  row lock, all its `matrix_sessions` rows, device tables, one transaction; lock order devices -> matrix_sessions), so a legacy session that survives is an error, never a silent 200;
  the caller's raw JWT must be denylisted durably (a failed insert => 500; the ETS entry of the node stays, so the token is dead there). A login committing after a device's teardown
  survives whole (point-in-time semantics). The legacy part of `/logout/all` keeps its best-effort contract (LL11).
- **R18 `DELETE /devices/{id}` / `POST /delete_devices`** are unchanged: they already end an OAuth session completely; the rejection for OAuth sessions needs story 5/6.
- **R19 Deactivation and GDPR erasure.** Admin deactivation already kills OAuth sessions; the erasure now ends OAuth and legacy sessions best effort after the commit.
- **R20 After revocation** the access token is `401 M_UNKNOWN_TOKEN` WITHOUT `soft_logout` (absent is a consistency choice, `false` is spec-equal) and the refresh token is `invalid_grant`.
- **R21 No audit rows, minimal logging.** INFO `outcome=revoked|ignored client_id_match=true|false|absent` (+ user, device and the STORED client id on revoked);
  the presented `client_id` (attacker controlled), token, hint and hashes are never logged.
- **R22 Redaction.** `token` is already redacted; `/oauth2/revoke` joins the names-only query paths; the request body is never captured.
- **R23 Metadata truthfulness.** `revocation_endpoint` and `revocation_endpoint_auth_methods_supported: ["none"]` are now true; every advertised endpoint exists.
- **R24 Facade contract.** `oauth_revoke_token/1 :: {:ok, :revoked, info} | {:ok, :unknown} | {:error, :unavailable}`, `oauth_end_user_sessions/1 ::
  {:ok, [device_id]} | {:error, :unavailable}`, both documented, never raising.

## Legacy coexistence (story 5)

Story `oauth-legacy-coexistence` (2026-10-10, oracle gate 2026-10-10) completes the parallel operation of the two
authentication APIs (spec decision 6): every `matrix_sessions` row carries `auth_api = legacy | oauth` and a session only
ever uses the API it was issued by. It adds the OAuth-aware compatibility surface and fixes the coexistence gaps found by
a touchpoint audit. Decisions (prefix `C`, so they never collide with D1-D23, T1-T33, R1-R24):

- **C1 Module boundaries (ADR-020).** The Matrix domain learns whether OAuth is offered ONLY through `Nebu.OAuth.oauth_aware?/0` (the shared predicate `Nebu.OAuth.Config.live_state/0`
  `{:live, _}`, also behind the kill switch of token / JWKS / openid-configuration and by construction behind `auth_metadata` answering 200); the Matrix domain never names `Nebu.OAuth.Config` / `Metadata`. The web layer and the Admin UI reach the atomic device teardown only through `Nebu.Matrix.end_device_session/2`.
- **C2 When the OAuth-aware flags are advertised: fail closed.** Only while OAuth is offered (`:enabled` and a valid issuer == `auth_metadata` 200, evaluated per request on top of the per-node config cache (cached per node for at most `NEBU_OAUTH_CONFIG_CACHE_MS`, HY1), so a runtime toggle flips both within that time). Disabled, an invalid issuer, an unreadable config or an exception => the keys are absent and `GET /login` is still `200` (login flows are needed by legacy clients in every state; the response is then byte-identical to the pre-broker one). `m.login.sso` is ALWAYS offered. Story 9 flips `/versions` on the same predicate `Nebu.OAuth.oauth_aware?/0` (done, V2); `account_management_uri` was absent until story 6 (resolved: advertised since story 6, A18).
- **C3 Field placement and shape.** On the `m.login.sso` flow object only: `oauth_aware_preferred: true` (Matrix v1.18) and the unstable twin `org.matrix.msc3824.delegated_oidc_compatibility: true` (matrix-js-sdk 41.3.0), JSON booleans, never `false`; the `m.login.token` flow never carries them; no `unstable_features` entry.
- **C4 `action` parsing.** The stable `action`, else the unstable `org.matrix.msc3824.action`; only the exact values `login` / `register` count, everything else (absent, empty, other case, `action[]=`, over-long) is ignored and never a 4xx; a valid stable value wins, an invalid stable one falls through to the unstable one; a repeated key resolves to the last value. Ignoring unknown values is conformant; the mapping `register` => `prompt=create` is a Nebu extension. The raw value is never forwarded (only the mapped `prompt`) and never logged (C6).
- **C5 `action` mapping and gating.** `GET /login/sso/redirect[/{idpId}]` only (not the UIA fallback, not the OAuth leg): while OAuth is NOT offered `action` is ignored entirely (URL byte-identical to today); while offered, `action=register` replaces `prompt=login` by `prompt=create` iff the IdP discovery document lists `create` in `prompt_values_supported` (a list), exactly one `prompt` parameter, otherwise `login`. `action` is honoured for the advertised provider `oidc` or no `{idpId}`; an arbitrary `{idpId}` behaves as today. Error order unchanged (bad `redirectUrl` 400 first, discovery failure 503).
- **C6 No new secrets, no raw values in logs.** `action` is attacker-controlled. On `GET /login/sso/redirect[/{idpId}]` the DEBUG query-string capture of `RequestLogger` masks the VALUE of every key that starts (case-insensitively) with `action` or `org.matrix.msc3824.action` (so `action[]`, `Action`, `org.matrix.msc3824.action[]` too); `redirectUrl` and the other parameters keep today's capture (the redirect is NOT a names-only path). No new log line contains the raw value.
- **C7 OAuth callers are refused at device deletion.** `DELETE /devices/{id}` and `POST /delete_devices` answer `403 M_FORBIDDEN` ("Device deletion is not available for OAuth sessions; use the account management page.") when the `:auth_api` assign set by `OidcPlug` at authentication time is `oauth`, as the FIRST step: before the IDOR guard, the body validation and the UIA gate (no `uia_sessions` row, no existence oracle, also for an empty or non-JSON body); an expired token gets `401` + `soft_logout` from the auth layer first. Basis: the UIA API is not compatible with the OAuth 2.0 API (Matrix v1.18); device deletion for OAuth sessions is the account page (story 6, item w). Matrix v1.17 exempts application-service callers from UIA on device deletion; Nebu has no appservice API, so no exception exists. Legacy callers are unchanged.
- **C8 Why 403 `M_FORBIDDEN`.** The spec defines no error for this case. `401` + UIA flows is wrong (no stage an OAuth client can complete; `m.oauth` is valid only on `/keys/device_signing/upload`), `M_UNRECOGNIZED` is wrong (the endpoint exists and works for legacy sessions on the same server), `403 M_FORBIDDEN` says "not with this token" and is non-retryable (oracle O1).
- **C9 UIA freshness is legacy-only.** `MatrixSessionStore.refresh_auth_time/2` updates only `auth_api = 'legacy'` rows; the `auth_time` of an OAuth session (IdP login time) stays reserved for the story-6 re-auth.
- **C10 Account endpoints stay absent.** `/account/deactivate`, `/account/password`, `/account/3pid*` and `/register` are not routed (known deviations, not pinned as correct: `404 M_NOT_FOUND` instead of the spec's `M_UNRECOGNIZED`, and an unauthenticated `POST /register` answers `401` before the 404); `GET /capabilities` reports `m.change_password` and `m.3pid_changes` as false; `/keys/device_signing/upload` was unchanged for OAuth callers in story 5 (resolved: `m.oauth` since story 6, A14).
- **C11 A raw JWT never writes the keys of an OAuth device.** `DeviceBinding.put/4` reports `{:error, :oauth_device}` for a refused binding; the lazy bind of `POST /keys/upload` runs first and answers `403 M_FORBIDDEN` (the G1 text) without any key write; the legacy raw-JWT `POST /login` answers `500 M_UNKNOWN "Login failed, please try again."` when the binding is refused or its `devices` upsert failed (oracle O4: a JWT bound to a missing device is refused, so handing it out would loop the client into logout). The opaque branch is unchanged.
- **C12 Atomic device teardown for every non-preserved deletion.** `delete_one_device/3` and `Nebu.Matrix.delete_user_device/2` use `Nebu.Matrix.end_device_session/2` (devices-row lock, every `matrix_sessions` row of the device, device tables, one transaction, then the confirmed JWT kill-switch and the legacy session rows), so a concurrent OAuth rotation cannot leave a working token behind a deleted device. Failures: `DELETE /devices` and `/delete_devices` answer `500 M_UNKNOWN` (every id is attempted), the Admin UI shows an error and a `failure` audit row. The preserved own-device path of a fresh-UIA self-delete is unchanged. Residual (follow-up x): the legacy `rotate_tokens/1` takes no `devices` lock.
- **C13 The JWT kill-switch never turns a bound JWT into a working unbound one.** `TokenDenylist.revoke_by_hash/2` reports a failed database write (`{:error, :no_exp}` without an expiry); the one shared `DeviceBinding.kill_device_jwts/3` deletes only the bindings whose denylist write was confirmed (a kept row => `{:error, :partial}` and a WARNING); `DeviceBinding.lookup/1` marks a binding REFUSED when its device has an OAuth session or no `devices` row any more, so a kept binding kills the JWT through the database on every node (Kassandra story-3 I-6 resolved). Two follow-ons: `POST /login` with a raw JWT checks the denylist (a revoked JWT => `403 M_FORBIDDEN`) and `DeviceBinding.put/4` never re-points an existing binding to another device (refused => the login answers `500`), so a binding kept by the kill-switch cannot be revived (Kassandra L-1). The preserved own-device path of a fresh-UIA self-delete is fail closed, not symmetric across token kinds: an opaque caller's session simply continues, a raw-JWT caller's JWT keeps its binding (not denylisted) but the device row is gone, so `lookup/1` refuses it after the node's 60 s lookup-cache TTL (`401 M_UNKNOWN_TOKEN`, no `soft_logout`): it lives for the request that deleted its own device (and the cache TTL) only.
- **C14 The unbound raw-JWT path stays for legacy.** An unbound raw IdP JWT authenticates device-less, also for a user with only OAuth devices; it can never become or act as an OAuth device (C11, T25). Kept (accepted risk of parallel operation; follow-up u refuses it when legacy is deprecated).
- **C15 Device take-over across APIs.** An approved OAuth client can pick the id of the user's legacy device (T7) and a legacy login the id of an OAuth device (T26); both are spec-conformant and need an interactive login of the same user; the residual risk is gate item (i). Documented, not changed (Kassandra story-3 I-5 accepted).
- **C16 OAuth sessions while OAuth is switched off.** `OidcPlug` does not consult `oauth_enabled`: existing OAuth sessions keep authenticating until their access token expires (at most `oauth_access_token_ttl_seconds`, max 3600 s), their refresh fails with the T22 404 (no `error`: retryable, not a logout) and changes no row, revoke and `/logout` still end them. **Switching off therefore SUSPENDS OAuth, it does not revoke it** (story-9 review F-2): re-enabling revives every stored, unexpired session (a stolen refresh token included) until `session_expires_at`; a real revocation is `bin/nebu rpc 'Nebu.Release.revoke_all_oauth_sessions()'` (07-deployment, follow-up (ai); story oauth-client-revocation CR10 replaced the former runbook SQL, which left devices, keys, JWT bindings and codes behind).
- **C17 `/whoami`, `/refresh`, `RefreshWorker`, media.** Verified unchanged: `/whoami` returns the bound `device_id` for OAuth and opaque legacy sessions; `/refresh` and the worker act on `auth_api = 'legacy'` rows only; media routers run the same `OidcPlug`.
- **C18 Admin device list.** OAuth devices are listed (they are `devices` rows) and admin deletion ends their sessions (atomically, C12); the list shows no owning API (follow-up v).
- **C19 No audit rows, no new config, no migration.** Consistent with T29 / D20 / R21; admin device deletion keeps its audit row (now also on failure). The only new application env is the test-only `:device_binding_put_override`, compiled out outside `MIX_ENV=test`.
- **C20 Deprecation path (decision 6: "until one of the two is deprecated").** Documented, not implemented: deprecating LEGACY introduces a `legacy_login_enabled` switch (`GET /login` stops advertising `m.login.token` / the SSO flow for new logins, `POST /login` refuses new legacy logins, `/refresh` and the `RefreshWorker` are removed, legacy sessions are not migrated and run out at `expires_at`, the raw-JWT path (follow-up u) goes with it); deprecating OAuth is `oauth_enabled = false` (discovery back to the IdP passthrough, the OAuth-aware flags disappear, C2; existing OAuth sessions die at their next refresh, C16; revoke stays live).

The deviations recorded by earlier stories are not changed by story 5: the legacy `POST /logout` user-wide wipe that keeps devices (R16, gate item r) and the legacy-to-legacy device reuse that does not invalidate earlier legacy tokens (story-3 oracle C8, follow-up f) stay open follow-ups.

Coexistence touchpoint audit (the Legacy / OAuth columns describe the state AS FOUND by the audit; the verdict column the state after story 5):

| Touchpoint | Code | Legacy (as found) | OAuth (as found) | Verdict (after story 5) |
|---|---|---|---|---|
| Opaque bearer auth | `OidcPlug.call_opaque/2` | ok | ok, assigns `:auth_api` | ok |
| Raw IdP JWT auth | `OidcPlug.call_jwt/2` + `DeviceBinding.lookup/1` | ok | JWT bound to an OAuth device refused (T25 c) | gap closed (C13) |
| Unbound raw JWT | `call_jwt/2` | legacy exception | cannot act as an OAuth device | kept (C14) |
| `POST /keys/upload` lazy bind | `maybe_bind_jwt_device/3` | ok | refused bind still wrote keys | gap closed (C11) |
| `POST /login` device reuse | `HttpPublic` (T26) | earlier legacy tokens survive (follow-up f) | OAuth rows deleted | not changed by story 5 |
| `POST /refresh`, `RefreshWorker`, `/oauth2/token` refresh | `auth_api`-filtered stores | ok | isolated | ok (T27) |
| `POST /logout` | `protected.ex` | user-wide wipe (gate r) | current device only | not changed by story 5 |
| `POST /logout/all` | story 4 R17 | all | all | ok |
| `DELETE /devices`, `/delete_devices` | `uia_gate/4`, `delete_one_device/3` | UIA `m.login.sso` | UIA not usable, lockless teardown | closed (C7, C12) |
| UIA SSO completion | `Uia.complete/2` | ok | refreshed OAuth `auth_time` too | closed (C9) |
| `/keys/device_signing/upload` | `do_device_signing_upload/1` | ok | no `m.oauth` | closed by story 6 (A14) |
| `/account/deactivate`, `/account/password`, `/account/3pid*`, `/register` | not routed | absent | absent | ok (C10) |
| `/whoami`, media, admin deactivation, GDPR erasure | shared | ok | ok | ok |
| Admin device list / delete | `Nebu.Matrix` facade | ok | listed, lockless teardown | closed (C12), marker (follow-up v) |
| `GET /login` | `HttpPublic.login_flows/1` | flows | no `oauth_aware_preferred` | closed (C1-C3) |
| SSO redirect `action` | `SsoLogin.redirect/1` | ignored | ignored | closed (C4-C6) |
| T7 issuance JWT kill | `OAuthSession.kill_bound_jwts/2` | - | best effort (I-6) | closed (C13) |

## Account management and `m.oauth` (story 6)

Story `oauth-account-management` (2026-10-10, oracle gate 2026-10-10; Matrix v1.18 "OAuth 2.0 API" account management, MSC4191,
the `m.oauth` UIA stage) gives OAuth users the two things the spec offers instead of the User-Interactive Authentication their
clients cannot perform (C7): a web page under the Nebu origin where they list devices, sign a device out and approve the reset of
their cross-signing identity, and the `m.oauth` stage on `POST /keys/device_signing/upload`. `account_management_uri` and
`account_management_actions_supported` join the `auth_metadata` document; `oauth_enabled` stays false. Decisions (prefix `A`, so
they never collide with D1-D23, T1-T33, R1-R24, C1-C20):

- **A1 Module boundaries (ADR-020).** OAuth domain: `Nebu.OAuth.Account` (HTTP orchestration), `Nebu.OAuth.AccountStore` (inline SQL, migration 000043), `Nebu.OAuth.AccountPages` (the renderer). Matrix domain: facade functions in `Nebu.Matrix` only (`account_identity/1`, `account_devices/1`, `account_profile/1`, `cross_signing_reset_requests/1`, `approve_cross_signing_reset/2`, `decline_cross_signing_reset/2`, `purge_expired_uia_sessions/0`, implemented in the private `Nebu.Matrix.AccountManagement`), reused: `idp_authorize_location/2`, `idp_complete_login/4`, `end_device_session/2`. Matrix to OAuth: ONE function, `Nebu.OAuth.cross_signing_reset_url/0` (`{:ok, url} | :unavailable`).
- **A2 Path.** `account_management_uri = <issuer>/account` (the issuer has an empty path, T31); `forward "/account"` in the router (before `/_matrix` and the catch-all): `GET /account`, `GET /account/reauth`, `POST /account/devices/delete`, `POST /account/cross_signing_reset/approve|decline`, `POST /account/logout`; anything else `404`, a wrong method (also `OPTIONS`) `405` + `Allow`. The reverse proxies must route `/account` and `/account/*` to the server (gate item (m) is extended; the cloud-init templates are not changed here).
- **A3 Liveness, kill switch.** The page is live iff `Nebu.OAuth.Config.live_state/0` is `{:live, issuer}`, the SAME predicate as `auth_metadata` 200 and `oauth_aware?/0`: disabled or an invalid issuer => `404` page `unavailable`, an unreadable config => `503` page + `Retry-After: 5`, both before a rate-limit token or any DB access. Consequence (consistent with C16): OAuth sessions that survive an operator switching OAuth off cannot use the page; they can still `/logout` / revoke.
- **A4 No CORS, own body parsing.** `/account*` is browser navigation: the router skips `CORSPlug` for it (no preflight answer, no `access-control-*` header), `JsonBody` skips it, the POST handlers read their raw form body once through `Nebu.OAuth.FormPost.parse/1` (16 KiB, form-encoded, no query string, duplicates refused) and answer parse errors as the HTML `invalid_request` page.
- **A5 Actions.** Query parsed from the RAW query string (`+` is a space); a malformed encoding or a duplicated `action` / `device_id` => the default page with the fixed notice `invalid_request`. Advertised, in this order: `org.matrix.profile` (read only), `org.matrix.devices_list`, `org.matrix.device_view` (Element's sign-out entry: a prominent "Sign out this device" control), `org.matrix.device_delete`, `org.matrix.cross_signing_reset`. An absent or unknown action (also the not advertised `org.matrix.account_deactivate`) renders the default page (profile summary + device list): a Nebu choice the spec leaves to the server. `device_id` on an action that takes none is ignored; on the two device actions a missing, invalid, unknown or foreign id gets ONE answer (the device list with the notice `device_not_found`: no IDOR / existence oracle). Input aliases, never advertised: `org.matrix.sessions_list`, `org.matrix.session_view`, `org.matrix.session_end` and the bare names.
- **A6 IdP login through the shared callback.** A request without a valid session starts an IdP login with the ONE IdP client (ADR-022), the shared registered callback, the OIDC Scopes Law scope, PKCE S256, `prompt=login` and `max_age=0`; state `o2.acct.` + 43 base64url characters. `Nebu.OAuth.handle_idp_callback/1` dispatches `o2.acct.` to `Nebu.OAuth.Account` first and everything else to `Authorize` unchanged. Flow state in `oauth_account_login_requests` (not the node-local `SsoStore`): `state_hash`, SecretBox-encrypted IdP verifier, nonce, browser-binding hash, the validated return target (`return_action` NULL = the default page), `expires_at = now() + 600 s`, consumed by ONE atomic `DELETE ... RETURNING`, soft cap 10 000 live rows inside the INSERT. Browser binding cookie `nebu_acct_<16 hex>` (`HttpOnly; SameSite=Lax`, `Path` = the callback, `Max-Age=600`, `Secure` on https), constant-time compare, cleared on every outcome except `429`. The redirect after the callback comes ONLY from the consumed row (relative, encoded: open-redirect safe); the IdP refresh token is discarded.
- **A7 Identity, no provisioning, `auth_time`.** `Nebu.Matrix.account_identity/1` derives the user id exactly like the login and does an error-aware `is_active` read (a database error is `503`, never the fail-closed `active?/1`); NO provisioning: an unknown user gets the page `no_account`, a deactivated one `deactivated`. `auth_time` is the id_token claim ONLY (`iat` is no substitute): present => not older than the login request minus 60 s, else `reauth_failed`; absent => the session's `auth_time` is NULL: never fresh (FR14, gate y closed fail closed), one WARNING per hour per node without PII, the destructive actions answer `freshness_unavailable` (the earlier rule stamped the callback time on such a login, which was fail open). Dex reportedly ignores `max_age` and omits `auth_time` (oracle O5); the e2e scenario `@ac2-freshness` records the real behaviour.
- **A8 Browser session.** `oauth_account_sessions`: `session_hash` (SHA-256 hex of a 256-bit cookie value, the plaintext is never stored or logged), `user_id`, `auth_time`, `csrf_hash`, timestamps; idle 900 s sliding and absolute 3600 s (CHECK), both enforced in ONE atomic `UPDATE ... RETURNING`; rotation on every login (the replaced session is deleted in the same transaction), at most 20 sessions per user (the oldest is deleted). A deactivated user's next request deletes the session. Cookie on an https request (`conn.scheme` or the first `X-Forwarded-Proto` value, the same helper as the callback URL and `.well-known`): `__Host-nebu_account` (`Path=/; Secure; HttpOnly; SameSite=Lax`, no sibling-subdomain cookie tossing, follow-up (j); only this cookie is read on https); on plain http (dev / test) `nebu_account` (`Path=/account`). `SameSite=Lax`, not `Strict`: the cookie is set on a callback reached through a cross-site redirect chain. The browser session is NOT a Matrix device and never authenticates `/_matrix/*`.
- **A9 CSRF.** Every state change is a `POST` with a hidden `csrf_token`; only its SHA-256 is stored (constant-time compare), the page renders the token derived from the session cookie (HMAC-SHA256 of the cookie, 256 bits only the browser knows), so it is stable across tabs. Additionally an `Origin` header, when present, must equal the issuer origin and `Sec-Fetch-Site`, when present, must not be `cross-site`. Any failure => `403` page `forbidden`, nothing changed, one WARNING without values. The token check is independent of the Origin check, and CSRF is checked BEFORE freshness.
  Review cycle 1: `Referrer-Policy: same-origin` on `/account*` (under `no-referrer` browsers send `Origin: null` for the page's own form POSTs); `Origin: null` is accepted only with `Sec-Fetch-Site: same-origin` and the valid token; on the destructive POSTs fetch metadata, when present, must describe a user-activated document navigation (Kassandra F-1 (b)). The residual risk that a same-origin script (an XSS in Element Web served on the same host) can drive the approval is gate item (ag) (dedicated account origin or an accepted risk) before `oauth_enabled`; it is vacuous freshness (gate (y)) that makes it worse.
- **A10 Re-authentication.** Device deletion and the reset approval / decline need a FRESH session (`now - auth_time < 300 s`); the confirmation page of a stale session shows a "Confirm it's you" link (an `<a>`: the CSP `form-action 'self'` would block a form whose submission redirects to the IdP) to `GET /account/reauth`, which starts a new IdP login with the same return target. The POST re-checks freshness itself (stale => `303` notice `stale`, nothing changed).
- **A11 GET never mutates; PRG.** Destructive operations: GET shows a confirmation page, POST executes and answers `303` to `/account?action=...&notice=...` (fixed notice codes); a POST never renders its result, the one exception is `POST /account/logout` (`200`, `signed_out`).
- **A12 Device list.** `Nebu.Matrix.account_devices/1` is error-aware (an outage renders `503`, never "no devices"): the user's `devices` with `auth_api` / `client_id` of the newest live session; the OAuth app is shown as the registration's `client_name` labelled "App (name claimed by the app)" (escaped; story-3 (c) is made visible, not solved), last active (UTC), last IP, added; sorted by last activity; at most 500 rows rendered with a visible "N more devices not shown". Legacy and OAuth devices are listed (decision 6: both APIs in parallel).
- **A13 Device deletion.** Ownership by membership in the user's device list, then `Nebu.Matrix.end_device_session/2` (C12: `devices` row lock, every `matrix_sessions` row of the device of ANY `auth_api`, the device tables, one transaction, then the confirmed JWT kill-switch): `303` `device_deleted`; a failure => `500` page `server_error` (nothing changed); idempotent (a second POST => `device_not_found`). Decision 4 of the epic is fulfilled: OAuth sessions delete devices only here (gate item (w) is closed). Legacy-only users (no OAuth session ever) sign in (A6/A7 need only an existing `users` row) and sign out legacy devices the same way.
- **A14 `m.oauth` UIA on `POST /keys/device_signing/upload`.** Order unchanged up to the replacement: key-id collision `400`; no stored master => store `200`; "unchanged" => `200` (also with `auth`, before the approval is looked at; FIX of a pre-existing deviation: spec-correct is "`master_key` equals the stored one and every additionally SUPPLIED key equals the stored one", keys not supplied are not compared, a request without `master_key` is a replacement; it also turns a legacy master-only re-upload from `403` into `200`). Replacement by a LEGACY caller (decided by the `:auth_api` assign set at authentication time, never by a token lookup): `403 M_FORBIDDEN`, byte-identical (a known deviation: the spec requires a UIA challenge). Replacement by an OAuth caller while OAuth is not live: the same `403`. Replacement by an OAuth caller with `auth.session` (type absent, `m.oauth` or `org.matrix.cross_signing_reset`): ONE transaction, the atomic single-use consume of the approved session AND the key write (a failed write rolls the consume back => `500 M_UNKNOWN`). Otherwise `401` with exactly `flows: [{"stages": ["m.oauth"]}]`, `params["m.oauth"].url` = `<issuer>/account?action=org.matrix.cross_signing_reset` (byte-equal to `account_management_uri` + the action, https) and `session` (no `errcode` / `completed`: Element would enter its error state). The caller's still PENDING session for the same `(user, params)` is reused (Element asks twice and retries without polling), else a new one is minted with a CHECKED insert (failure => `500`, never a challenge for a session that does not exist); an approved-but-unconsumed session is never re-issued to an `auth`-less request. `params` binds the requesting device AND `keys_sha256`, the SHA-256 of the canonical JSON of ALL supplied keys: a retry with a different key set gets a new challenge. `m.oauth` appears only here, never in the flows of `DELETE /devices`, `/delete_devices` or the legacy fallback.
  Review cycle 1 (Kassandra F-2 / F-3): an approved PARTIAL replacement keeps the stored keys that were not supplied; the challenge is serialized per `(user, device)` (`pg_advisory_xact_lock`), keeps ONE pending request per `(user, device)` (an approved one is never touched), caps pending requests per user at 5; an OAuth replacement without any key answers `400 M_MISSING_PARAM`.
- **A15 Approval record = the UIA session row.** `uia_sessions` with `op = "cross_signing_reset"`, `stage_complete = TRUE` means "approved on the account page"; TTL 900 s from the challenge, an approval sets `expires_at = LEAST(expires_at, now + 600 s)`. Separation from the legacy SSO stage: `Uia.complete/2` and `Uia.load/1` exclude the op (an IdP login in the legacy fallback can never approve a reset), the approval functions touch only that op; new index `uia_sessions_user_op_pending_idx`.
- **A16 Approval page.** `action=org.matrix.cross_signing_reset` lists the user's pending requests (unexpired, not consumed, not approved; newest first, at most 20) with the REQUESTING device (name + id), the time and the warning; request-first (an approval always names ONE UIA session; a user-level "allow resets for 10 minutes" window is rejected because any holder of an access token of the user could use it). Approve / decline are single atomic conditional UPDATEs; approving request A never authorises request B; an unknown, foreign, expired, consumed or non-reset session => `reset_not_found`; a decline makes the client's retry get a NEW challenge.
- **A17 `auth_time` of OAuth sessions (DELIBERATE DEVIATION from the epic spec).** Spec section 8 said "`auth_time` muss auch bei OAuth-Sessions gesetzt werden (Login bzw. Re-Auth über die Account-Seite)". Story 6 does NOT write `matrix_sessions.auth_time` on an account login / re-authentication: story 3 sets it at issuance and C9 keeps the legacy UIA refresh away from OAuth rows; a browser re-authentication proves that the user is at THIS browser, not that the Matrix client holding a token is, so refreshing token rows would grant freshness to a possibly stolen token. Freshness for destructive OAuth-era actions lives on the account session (A10) and the explicit approval (A15). The spec sentence is amended accordingly.
- **A18 Metadata truthfulness.** `Metadata.build/1` adds `account_management_uri` (`<issuer>/account`) and `account_management_actions_supported` (exactly the five actions, in this order); the page is live under exactly the predicate the document answers 200 under, and the unstable alias and `/.well-known/openid-configuration` stay byte-identical (T31). Clients cache the document for 3 days.
- **A19 Abuse bounds.** Node-local bucket `{"oauth_account", ip}` (600/h per IP) charged by every `/account*` request and by the account branch of the IdP callback, after the live check and before any DB access (abuse control only; trusted-proxy gate item 1 applies); at most 10 000 live login requests and 20 sessions per user. Per-source caps are follow-up (aa).
- **A20 Look, accessibility, headers.** A standalone renderer (like `Nebu.OAuth.Pages`), NOT the admin layout: EEx templates compiled with `Phoenix.HTML.Engine` (auto-escaping: every attacker-controlled name renders as inert text), ONE inline CSS block allowed by its SHA-256, CSP `default-src 'none'; style-src 'sha256-...'; img-src 'none'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'`, `X-Frame-Options: DENY`, `Cache-Control: no-store`, no script, no inline handler, no external resource. WCAG 2.1 AA hooks (`lang`, one `main`, one `h1`, `nav aria-current`, table caption and scopes, accessible names with the device, `role="status"` / `role="alert"` notices, focus outline, contrast, touch targets, 320 px); e2e hooks `data-page`, `data-action`, `data-role`. Error pages: `<main data-page="account-error" data-error="<code>">`; status per code: `access_denied`, `no_account`, `deactivated`, `reauth_failed`, `forbidden` 403, `invalid_state`, `invalid_request` 400, `server_error` 500, `rate_limited` 429, `method_not_allowed` 405, `not_found` 404, `unavailable` 404 (not live) / 503.
- **A21 No audit rows, minimal logging.** Consistent with T29 / R21 / C19: INFO lines name the user and the device only; WARNING for a missing `auth_time` and for a failed CSRF check (no values); never a cookie value, CSRF token, state, IdP code / token / claim, UIA session id or hash. Audit rows for reset approvals and device deletions are follow-up (ab).
- **A22 Redaction.** `PayloadRedactor` gains `csrf_token` and redacts the `session` of a UIA CHALLENGE response (`flows` + `session`); the account POST bodies are never captured (JsonBody skip); `RequestLogger` logs `/account` and `/account/*` query strings with parameter NAMES only.
- **A23 Purge.** `Nebu.Workers.OAuthFlowPurgeWorker` also calls `Nebu.OAuth.purge_expired_account_state/0` (batched deletes of expired login requests and sessions) and `Nebu.Matrix.purge_expired_uia_sessions/0` (the so far never scheduled `Uia.cleanup_expired/0`, expired rows only); `purge_expired_flow_state/0` keeps its shape.
- **A24 Migration 000043.** New tables `oauth_account_login_requests` (no UPDATE grant: rows are never updated; the migration revokes a default-privilege UPDATE) and `oauth_account_sessions`, the index above, expiry indexes, grants to `nebu_app`, RLS enabled AND forced with open policies per granted command (the 000041 pattern), no `server_config` key; no `return_session_id` column (review cycle 1: never used). 000040-000042 are untouched.
- **A25 OAuth-aware clients.** OAuth-aware clients MUST deep-link to the account page to sign out other devices; Nebu lands them on the confirmation page after at most one IdP login. Element also shows these links for LEGACY sessions once the metadata carries `account_management_uri`, so the page serves legacy-only users too (A13). Deactivation is not supported (not advertised).
- **A26 Consent (Kassandra story-3 I-5 / gate (i)).** No consent screen is added; the device list names the OAuth app of each device, and the account login is protected by `max_age=0` plus the A7 freshness check where the IdP emits `auth_time`. The same check at the AUTHORIZE callback stays gate (i). **Superseded by FR1/FR14** (story oauth-authorize-freshness): the authorize flow has a consent screen on every authorization, and the account page fails closed without `auth_time`.
- **A27 `/logout/all` and admin.** `/logout/all` keeps working without UIA (R17); account sessions are not Matrix sessions (a user ends one by signing out of the page or after 15 minutes idle). Admin deactivation makes the next account request delete the session. No admin UI change (follow-up (v)).

## `/versions` switch and activation (story 9)

Story `oauth-versions-switch` (2026-10-12, the last story of the epic; oracle gate 2026-10-12) announces Matrix v1.15 exactly while the OAuth 2.0 API is offered, consolidates the liveness predicate, proves the live metadata with a conformance contract and documents activation and rollback (`docs/architecture/07-deployment.md`). It closes no gate item and enables nothing: with `oauth_enabled = false` the new code is dormant (`/versions` is today's v1.1-v1.11 body). Decisions (prefix `V`):

- **V1 Exact version lists.** Offered: the 15 consecutive entries `v1.1` ... `v1.15` in numeric order; not offered: today's `v1.1` ... `v1.11` byte for byte. Two literal attributes in `Nebu.Matrix.HttpPublic` (never computed from a range: `v1.10` sorts before `v1.2` as a string), nothing above v1.15 (v1.16+ was not audited). The full consecutive set is advertised because clients test single entries (`includes("v1.4")`).
- **V2 One predicate, one place (ADR-020).** The Matrix side asks only `Nebu.OAuth.oauth_aware?/0` (once per request). `Nebu.OAuth.Authorize.live_issuer/0` and `Nebu.OAuth.Http.auth_issuer/1` now delegate to `Nebu.OAuth.Config.live_state/0` (no behaviour change); `Metadata.normalize_issuer/1` is called only by `live_state/0` and `Metadata.build/1`. `POST /oauth2/register` keeps `Config.enabled?/0` (a recorded deviation: it stays live with an enabled switch and an invalid issuer). `Nebu.Web.Plugs.OAuthDiscovery` keeps its state-only switch (decision 7: passthrough only on a positively read `:disabled`; N-4: 503 on `:unknown`). Cached per node for at most `NEBU_OAUTH_CONFIG_CACHE_MS` (HY1, follow-up I-12, DONE).
- **V3 Placement.** The exact `get "/_matrix/client/versions"` stays in `Nebu.Web.Router` (before `forward "/_matrix"`, no `OidcPlug`) and only calls `Nebu.Matrix.HttpPublic.versions/1` (body: the pure `versions_body/1`); not a `forward` (it would capture `/_matrix/client/versions/...`).
- **V4 Fail closed, never 5xx.** Disabled, an invalid issuer, an unreadable `server_config`, no repo, a raise or an exit => the v1.11 answer with 200 (the load balancers health-check this path). Review cycle 1 (Kassandra F-1): the `server_config` read on THIS path is bounded (`Config.live_state(bounded: true)`: 500 ms pool checkout and query timeout, so a slow or locked table fails closed within the bound instead of hanging every health check) and its WARNING is throttled to one per minute per node; every other caller keeps the default timeouts.
- **V5 `unstable_features`.** Exactly `uk.half-shot.msc2666.query_mutual_rooms` in both states; never an OAuth MSC or `*oauth*` key (stable since v1.15; MSC3824 is a `GET /login` field).
- **V6 Authentication ignored.** matrix-js-sdk sends `/versions` authenticated (MSC4026); the answer is independent of `Authorization` (never 401); the CORS preflight allows `Authorization`.
- **V7 Caching.** `Cache-Control: no-store` on both 200 variants (a flip is visible on the next fetch); the 3-day `public, max-age=259200` of the metadata is unchanged (I-2).
- **V8 Cost.** No rate limit; one indexed `server_config` read per request IN EVERY DEPLOYMENT, also with `oauth_enabled = false` (the `live_state/0` read, as `GET /login`; the OAuth surface is dormant, this code path is not), bounded to 500 ms (V4); I-12 (per-node TTL cache) now names `/versions` and the health checks.
- **V9 Parity and runtime toggle.** Per config state the surfaces answer as in the parity table below; `"v1.15" in versions` IFF `auth_metadata` is 200 IFF the SSO flow carries the OAuth-aware keys IFF `/.well-known/openid-configuration` is 200 IFF `/account` is not the `unavailable` page; a toggle flips every surface within `NEBU_OAUTH_CONFIG_CACHE_MS` (default 2 s) on every node (HY1/HY2).
- **V10 Conformance contract.** `oauth_conformance_contract_test.exs` derives every URL from the LIVE document (crawler: never the router fall-through, `M_NOT_FOUND` or `M_UNRECOGNIZED`), has one test per field, a key guard (a new top-level key needs a contract entry; `device_authorization_endpoint` / `prompt_values_supported` absent) and the byte identity of the three discovery paths. Green before and after story 9: it guards the refactor.
- **V11 matrix-js-sdk replay.** `tests/matrix_compat/oauth_metadata_test.js` validates the live metadata and checks that `getAuthMetadata()` uses the stable path for `versions_on` and the unstable one for `versions_off`; run from a scratchpad copy only.
- **V12 Activation checklist and rollback (docs only).** `docs/architecture/07-deployment.md`; rollback: within `NEBU_OAUTH_CONFIG_CACHE_MS` (default 2 s) on every node => v1.11, `auth_metadata` 404, flags gone, `/oauth2/*` and `/account` 404, revoke still live (R13), existing OAuth access tokens keep authenticating until they expire (C16). **Forced re-login:** the two APIs are mutually incompatible, an OAuth session can never continue as a legacy session; every OAuth user has to log out and log in again with legacy SSO, a drain does not avoid it (oracle O8). Switch-off SUSPENDS OAuth, it does not revoke it (C16): OAuth access tokens keep working until they expire, the refresh answers a retryable 404 and re-enabling revives unexpired sessions; the way to a real revocation (`Nebu.Release.revoke_all_oauth_sessions/0` over `bin/nebu rpc`, story oauth-client-revocation CR10) is in 07-deployment (follow-up (ai)). The switch was SQL-only when this story was written; since story admin-oauth-switch ("Admin UI switch" below) it is also written by the Admin UI; the exact SQL activation / rollback statements stay in 07-deployment (the emergency path).
- **V13 Gates are not closed by this story.** The merge into the epic branch is fine (dormant); `oauth_enabled = true` and a release note claiming OAuth need the gate items of the story-9 state: 1, 2, 4, h, i, l, m, n, r, y, ac, ag; since the bugfix legacy-logout-per-device (r) is closed and (s) `device_lists.changed` on every device deletion is added (see `07-deployment.md`).
- **V14 Obligations audit v1.12-v1.15** (table below). G1 `GET /_matrix/client/v1/room_summary/{roomIdOrAlias}` is CORE in v1.15 and absent: follow-up (ac), a GATE before `oauth_enabled` and before any release claiming v1.15 (spec 3a was wrong to call it optional and is corrected); G2 `createRoom` ignores `topic`, G3 pre-existing unrouted endpoints (`POST /user_directory/search`, `GET|POST /publicRooms`, push-rule writes, `POST /keys/claim`): follow-up (ad), non-gating. No gap is implemented here.
- **V15 Out of epic scope.** Story 7 (Device Authorization Grant, RFC 8628) and story 8 (mTLS / `private_key_jwt` for machine clients) are deliberately NOT implemented in epic `oauth-broker`: no `device_authorization_endpoint`, no `device_code` grant, no certificate-bound tokens; the data-model hooks stay prepared (`oauth_clients.token_endpoint_auth_method`). Story 10 (application-service API) is a separate epic. The version list does not depend on them.
- **V16 Doc consistency pass.** Stale statements are fixed in the same commit; historic statements carry a "(resolved: ...)" marker.
- **V17 No migration, config, env, audit row, rate-limit bucket or log line.**
- **V18 `/capabilities` unchanged** (`m.change_password: false`, `m.3pid_changes: false`, no `m.get_login_token`).
- **V19 Other methods pinned as measured.** `OPTIONS` is answered by `CORSPlug` (204, allows `Authorization`); `POST` / `PUT` / `HEAD` fall to Protected (`401 M_MISSING_TOKEN`: a deviation from the spec's `405 M_UNRECOGNIZED`, follow-up (af)); `/_matrix/client/versions/` gives the same answer; `/_matrix/client/v3/versions` is unrouted (`401`, follow-up (ae): health checks must probe `/_matrix/client/versions`; fixed in `deploy/` by story P5: Helm readiness, the AWS target group, the UpCloud / Stackit LB probes and the RUNBOOKs use `/_matrix/client/versions`, Helm liveness uses the dependency-free `/health`).

Registrations: only `pending` registrations are purged (`OAuthPendingPurgeWorker`, never approved or rejected rows) and the FK `ON DELETE RESTRICT` forbids deleting a registration with an active session (the spec's "MUST NOT delete a registration with an active session"); a re-registration per flow dedups to the same approved `client_id` without a new approval.

Parity table (per config state; S1 enabled + valid issuer, S2 enabled + invalid issuer, S3 disabled, S4 unreadable `server_config`):

| Surface | S1 | S2 | S3 | S4 |
|---|---|---|---|---|
| `GET /_matrix/client/versions` | v1.1-v1.15 | v1.1-v1.11 | v1.1-v1.11 | v1.1-v1.11 |
| `GET /v1/auth_metadata` | 200, 3-day cache | 404 `M_UNRECOGNIZED` | 404 | 404 `no-store` |
| unstable `auth_metadata` | 200 (same bytes) | 404 | IdP passthrough | 503 `M_UNKNOWN` |
| `auth_issuer` (v1 + unstable) | Nebu issuer | 404 | IdP passthrough | 503 `M_UNKNOWN` |
| `GET /login` OAuth-aware keys, SSO `action` | present, honoured | absent | absent | absent |
| openid-configuration / JWKS / token | live | 404, no `error` | 404, no `error` | 503 `{}` |
| `/oauth2/authorize` | live | 404 | 404 | 404 |
| `/oauth2/register` | live | live (deviation, `Config.enabled?/0`) | 404 | 404 |
| `/account*` | live | 404 page | 404 page | 503 page |
| `/oauth2/revoke` | live | live (R13) | live (R13) | 503 `{}` |

Obligations introduced by Matrix v1.12-v1.15 (server MUSTs and required behaviours; changelogs plus a diff of every MUST / REQUIRED sentence of the v1.11 and v1.15 CS API pages):

| Ver. | Obligation | Nebu status |
|---|---|---|
| 1.12 | Media download / thumbnail `Content-Type`, `Content-Disposition` (MSC2701/2702) | done (bugfix media Content-Type / filename) |
| 1.12 | Historical push actions `dont_notify` / `coalesce` ignored | not applicable (no push-rule writes routed) |
| 1.12 | Account locking (MSC3939), profile `403`, guest media, `via`, login fallback | not applicable (no lock feature, no guests, no federation) |
| 1.12 | `m.marked_unread` room account data (MSC2867) | done (optional module) |
| 1.13 | `POST /rooms/{roomId}/report` (MSC4151) | not applicable (Reporting Content optional; answers `404 M_NOT_FOUND`, (af)) |
| 1.13 | `M_USER_SUSPENDED`, requestToken error codes | not applicable |
| 1.13 | `/keys/claim` OTK order (MSC4225) | not applicable (E2EE excluded; unrouted, (ad)) |
| 1.14 | `POST /users/{userId}/report` (MSC4260), `server_name` removed from join / knock, `instance_id` | not applicable / optional |
| 1.15 | OAuth 2.0 API, `auth_metadata`, mutually incompatible APIs, `M_UNRECOGNIZED` when unsupported | done (stories 1-6), proven by the conformance contract |
| 1.15 | `GET /_matrix/client/v1/room_summary/{roomIdOrAlias}` (MSC3266) | GAP G1: absent, CORE; follow-up (ac), GATE before `oauth_enabled` |
| 1.15 | `m.topic` block, `createRoom` `topic` => `m.room.topic` with a text/plain mimetype (MSC3765) | GAP G2, pre-existing: `createRoom` ignores `topic`; follow-up (ad) |
| 1.15 | "Public" rooms definitions for profile look-up / user directory / presence | profile done; user directory GAP G3 (unrouted); presence unchecked |
| 1.15 | Well-known URIs on the server name's host | done (`/.well-known/matrix/client`) |

## Legacy logout per device (bugfix legacy-logout-per-device)

Closes gate item (r) (the legacy `POST /logout` was the user-wide wipe, R16) and follow-up (x) (legacy `rotate_tokens/1` took no `devices` lock). Matrix CS v1.18: `/logout` "invalidates an existing access token ... The device associated with the access token is also deleted. Device keys for the device are deleted alongside the device." The OAuth branch (R15) was already conformant. Decisions:

- **LL1 Scope: the presented credential's device, nothing else.** A legacy `/logout` (opaque Nebu token, raw IdP JWT bound or unbound) ends exactly the device the credential is bound to SERVER-side (`matrix_sessions.device_id` of the presented row, or `jwt_device_bindings.device_id`; both assigned by `OidcPlug` as `:device_id`, never request input). It never touches another device's rows of ANY `auth_api` and never runs the user-wide `invalidate_user_sessions`. The request body and query are ignored.
- **LL2 Device deletion is Matrix device deletion.** The SAME atomic, locked teardown as `/oauth2/revoke`, OAuth `/logout`, `DELETE /devices` and the account page: devices-row lock, every `matrix_sessions` row of `(user, device)` (the presented row, its pending / consumed rotated siblings, any other legacy row of a reused device id), device keys, one-time keys, fallback keys, the `devices` row; after the commit the JWT kill-switch of the device and its per-device legacy `sessions` / `sync_tokens`. Cross-signing keys (per user) stay. All credentials of the device die with it.
- **LL3 Re-check under the devices lock; never kill a newer session.** After the devices-row lock the transaction re-checks that the presented credential still belongs to that device (opaque: a `matrix_sessions` row of `auth_api = 'legacy'` with this hash and `(user, device)`, any state; bound JWT: the binding row, the `devices` row, and NO `auth_api = 'oauth'` row on the device). A miss (an OAuth login took the device id over, a concurrent logout won) deletes nothing: `{:ok, :unknown}`, answer `200 {}`. The opaque re-check deliberately does not exclude a device that also holds an OAuth row: deleting a device kills all its tokens. When the device has NO `devices` row (a legacy login ignores a failed `register_device`) the device's `matrix_sessions` rows are locked instead (`FOR UPDATE`, ordered by key), so a legacy refresh that commits first has its new row deleted by the following DELETE (cycle 1, L1). The lock wait is bounded to 2 s (`SET LOCAL lock_timeout`, like `lock_client!`): a timeout rolls back and answers `500 M_UNKNOWN`, the client may retry.
- **LL4 Bound raw JWT.** Order: the locked teardown first (a storage failure => `500 M_UNKNOWN`, nothing changed, the JWT still works); then the CHECKED denylist write of the presented JWT (jti key, hash fallback) on EVERY non-error result, i.e. on `{:ok, :ended}` AND on `{:ok, :unknown}` (after an OAuth take-over the binding deletion is best effort, so the JWT must be denylisted explicitly); a failed DB write => `500 M_UNKNOWN` (the ETS entry of this node is written). Never a silent `200` with a live credential.
- **LL5 Unbound raw JWT (`:device_id` nil).** `OidcPlug` degrades a failing binding read to "unbound"; `DeviceBinding.lookup/1` therefore never caches a database error, and the handler re-reads the binding uncached (`DeviceBinding.lookup_fresh/1`): a failing read => `500 M_UNKNOWN` with nothing deleted or denylisted, a found binding takes the LL4 path (cycle 1, L2). Only a confirmed unbound JWT is handled as follows. No device and no session row: the JWT is denylisted CHECKED until its `exp`, nothing else is touched (no other device, no user-wide wipe). DB write failure => `500 M_UNKNOWN` (dead on this node by the ETS entry). Follow-up (u) (refuse unbound JWTs) is unchanged.
- **LL6 Legacy opaque token.** One call of the facade (LL10); `:ended` and `:unknown` => `200 {}`; `{:error, :unavailable}` => `500 M_UNKNOWN` "Logout failed, please try again.", the session survives completely (rolled back). An opaque row with an empty device id deletes only the presented row and no device.
- **LL7 Idempotence.** A replay of the logged-out token never reaches the handler (`401 M_UNKNOWN_TOKEN`, no `soft_logout`). Two concurrent logouts with the same credential both answer `200 {}`; exactly one tears down (the other re-check misses).
- **LL8 The best-effort contract of R16 is replaced.** The legacy `/logout` reports storage failures (`500 M_UNKNOWN`) like R15 and `/logout/all` (R17). No rate limit, no audit row (R21 / C19 consistency).
- **LL9 Gate x: the legacy rotation takes the devices lock.** `MatrixSessionStore.rotate_tokens/1` reads `user_id, device_id` of the old row (no lock) and takes `SELECT 1 FROM devices ... FOR UPDATE` BEFORE the guarded soft-revoke UPDATE (the OAuth `lock_device_of/2` pattern). Lock order everywhere: (`oauth_clients` ->) devices -> matrix_sessions; the other legacy writers lock only `matrix_sessions` rows and never wait for a devices row, so there is no cycle. A teardown and a legacy `/refresh` of one device serialise: when the teardown wins the UPDATE matches 0 rows (`401 M_UNKNOWN_TOKEN`), when the rotation wins the teardown's later DELETE also removes the new row. No working token survives a deleted device.
- **LL10 ADR-020 surface.** Facade `Nebu.Matrix.legacy_logout_device/1` taking `%{kind: :opaque | :jwt, token:, user_id:, device_id:}` and returning `{:ok, :ended} | {:ok, :unknown} | {:error, :unavailable}` (never raises), on `Nebu.Matrix.OAuthSession.end_legacy_device/1` and `OAuthSessionStore.end_legacy_device/5` (the token is hashed inside, the `:oauth_session_repo` test seam applies). A SEPARATE function from the OAuth revocation entry points; `protected.ex` keeps only routing and the JWT denylist call.
- **LL11 `/logout/all` is unchanged.** The old legacy body (presented-token revoke + user-wide `invalidate_user_sessions`) is `legacy_user_wipe/2`, used ONLY by `/logout/all` (R17, I-14 stays open); admin deactivation keeps the user-wide wipe.
- **LL12 Out of scope, recorded.** `device_lists.changed` for peers on a device deletion does not exist in Nebu: follow-up (s) was RE-CLASSIFIED as a gate item before `oauth_enabled` for ALL deletion paths (SUPERSEDED by the phase-2 decision of 2026-10-13, epic SEC gate 3 G3-4: re-scoped to "before encrypted rooms are allowed (ADR-011 lifted) and before any release that claims E2EE", see the section "(s) re-scoped" below). Queued to-device messages do not exist (`sendToDevice` is unrouted); the txn-id dedup (`:NebuTxnDedup`, per user, node-local) is a pre-existing deviation (new follow-up row). Logging: one INFO line with the STATIC message `legacy logout` and Logger metadata `user_id`, `device_id`, `kind=opaque|jwt_bound|jwt_unbound`, `outcome=ended|unknown|failed` (never interpolated: a device id cannot forge fields; never a token, hash or jti).

## Gate items before `oauth_enabled` / story 2 merge (resolved: story 2 merged; the gates now apply to enabling OAuth and to the merge to `main` with an OAuth release note)

Deferred from security review cycle 4, NOT implemented in story 1 (tracked in
`docs/stories/oauth-broker/follow-ups.md`):

1. **Trusted-proxy client-IP resolution (F-1, MEDIUM, HARD GATE).** Resolve the client IP through
   an explicit, CIDR-gated `X-Forwarded-For` / `Forwarded` allowlist (default: none). Until then
   both reference deployments (nginx in front) share one per-IP bucket, so the strict per-IP limit
   is effectively global. Must be closed before `oauth_enabled` can be true or story 2 merges.
   **Phase-2 update (story oauth-trusted-proxy-client-ip): resolved in the server by this story**
   (`NEBU_TRUSTED_PROXY_CIDRS`, one resolution plug, one `Nebu.Web.ClientIP.get/1` helper for every
   per-IP consumer); activation still needs the operator verification of the CIDR list and of the
   proxy topology (section "Trusted-proxy client IP", Manual verification table). An empty or invalid
   list stays fail closed (shared buckets, never spoofable); a too-broad list is not safe.
   Story 2 confirms the gate: the per-IP buckets of `GET /oauth2/authorize` and of the OAuth branch
   of the IdP callback (`{"oauth_authorize", ip}`, `{"oauth_callback", ip}`) have the same weakness
   (behind nginx one shared bucket throttles every login).
2. **Bulk reject in the admin UI (F-1).** Recovery from a full pending list is otherwise one
   confirm-and-reject click per row (or SQL).
   **Resolved by story oauth-dcr-abuse-hardening** (AH8, AH9): "Remove pending registrations" (preview, native confirm, one audit row).
3. **Public-suffix check (F-4).** `client_uri` hosts that are public suffixes (`github.io`) and a
   warning badge on the approval page; also lets the per-host cap group by registrable domain.
   **Resolved by story oauth-dcr-abuse-hardening** (AH4, AH5, AH6): suffix hosts are refused, shared-hosting hosts get a badge, the cap groups by registrable domain.
4. **Per-host cap keyed on an attacker-asserted host (N-1, MEDIUM, gate, deferred from cycle 4).**
   `client_host` is the unverified host of the registrant's own `client_uri`: no DNS lookup, no
   proof of ownership. An attacker can therefore fill the per-host pending cap (default 20) for a
   REAL host (e.g. `element.company.com`) with 20 registrations of distinct metadata, and from
   then on every NEW registration for that host answers `503` for up to the pending TTL (30 days)
   or until an admin rejects the 20 rows one by one; the attacker can refill at will. That blocks
   the first OAuth login of the organisation's real client and of every new client version. In the
   other direction the cap does not stop an attacker, who rotates made-up hosts. Fix (together
   with item 1): key the cap on `(client_host, created_from_ip)`, or on a host-cap hit evict the
   OLDEST pending row of that host instead of refusing the new one (a legitimate client
   re-registers on every flow, so it re-appears); add "bulk reject by host" to item 2. Documented
   property until then: the per-host cap can be used for a targeted DoS of a host's registrations.
   **Resolved by story oauth-dcr-abuse-hardening** (AH1): the cap is keyed on (registrable domain, source), refuse-only (never evict); effective only with item 1 configured (AH12).

Also recorded: while `oauth_enabled` is true the metadata advertises `/oauth2/token|revoke`, which
did not exist before stories 3/4 and answered 404 (`/oauth2/authorize` exists since story 2) (resolved: all advertised endpoints exist since story 4; contract-tested in story 9); `Cache-Control: max-age=259200` on the metadata
makes a kill switch visible to clients only after up to 3 days (operator runbook note).

Story 3 update: `/oauth2/token` exists now (and `/oauth2/jwks`, `/.well-known/openid-configuration`),
but `/oauth2/revoke` answered the router's 404 until story 4 (live since story 4, see below), so the
advertised metadata was not complete and `oauth_enabled` stayed false until story 4 at the earliest. Item 1 (trusted proxy) also
covers the new per-IP buckets `{"oauth_token", ip}`, `{"oauth_token_refresh", ip}` and
`{"oauth_jwks", ip}` (the refresh bucket is deliberately generous because of the shared nginx peer).
New gate items (l) (detect a missing IdP refresh token at the IdP callback) and (m) (reverse-proxy
routes for `/oauth2/` and `/.well-known/openid-configuration`) are tracked in `follow-ups.md`. Gate (m) is closed in the reference templates by story P5 (routes incl. `/account`, `NEBU_TRUSTED_PROXY_CIDRS`, query-free access logs; verify after deploy, see Manual verification).

Story 4 update: `/oauth2/revoke` is live (also while OAuth is disabled, R13), so every advertised endpoint exists; `oauth_enabled`
stays false because of the gate items listed in the story-9 update below (stories 5, 6 and 9 are done). Item 1 (trusted proxy) also covers the per-IP bucket
`{"oauth_revoke", ip}`. New gate item (r): the legacy `POST /logout` wipes every session of the user (also OAuth sessions on other
devices) and keeps the devices (R16); non-gating follow-ups (s) `device_lists.changed` on device deletion and (t) optional IdP-side
revocation are tracked in `follow-ups.md`.

Story 5 update: OAuth sessions could not delete devices until story 6 (item w, closed): `DELETE /devices` and `/delete_devices` answer `403 M_FORBIDDEN` for OAuth callers. Gate item (r) remains open and MUST be closed before `oauth_enabled` (the story-9 `/versions` flip code exists and is dormant) by the bugfix run `legacy-logout-per-device`; story 9 flips `/versions` on `Nebu.OAuth.oauth_aware?/0` (done), the predicate that gates the OAuth-aware flags and `action`. The legacy `/logout` deviation and the legacy-to-legacy device reuse are not changed by story 5.

Story 6 update: the account page is live under the `auth_metadata` predicate (A3), gate (w) closed (OAuth sessions delete devices there, A13); (m) extended to `/account`: the reverse proxies must route `/account` and `/account/*`; the metadata advertises `account_management_uri` and `account_management_actions_supported` (A18); new items y-ab in `follow-ups.md`: (y) the IdP must emit `auth_time` for `max_age=0` (BLOCKING before `oauth_enabled`, together with (i)), (z) no deactivation / profile editing, (aa) per-source caps, (ab) audit rows. `oauth_enabled` stays false because of gate items 1, h, i, l, m, n, r, y and story 9. Item 1 (trusted proxy) also covers the per-IP bucket `{"oauth_account", ip}`.

Phase-2 update (story oauth-dcr-abuse-hardening): gate items 2, 3 and 4 and (h) are closed in the server, and (aa) for login requests (section "DCR and flow-state abuse hardening"); 4 and (h) are effective only with gate item 1 configured and verified.

Story 9 update: `/versions` lists v1.12-v1.15 exactly while `Nebu.OAuth.oauth_aware?/0` (the `auth_metadata` 200 predicate); the flip is dormant while `oauth_enabled` is false, and story 9 closes no gate. `oauth_enabled` stays false until the activation checklist (`docs/architecture/07-deployment.md`) is green: gate items 1, 2, 4, h, i, l, m, n, r, y, ac, ag (in particular (r) `legacy-logout-per-device` and (ac) `GET /v1/room_summary`, without which the v1.15 claim is not honest; (af) ships with (ac)). Status after bugfix legacy-logout-per-device: (r) is CLOSED and (s) `device_lists.changed` on every device deletion is a gate item, so the open set is 1, 2, 4, h, i, l, m, n, s, y, ac, ag (the list above is the story-9 state). Rollback semantics: switching off flips every surface within `NEBU_OAUTH_CONFIG_CACHE_MS` (default 2 s) on every node (HY1); OAuth sessions force a re-login (the APIs are mutually incompatible). Stories 7 and 8 are out of epic scope (V15). Bugfix legacy-logout-per-device: gate item (r) closed (LL1-LL12); follow-up (x) closed (LL9).

Phase-2 update (story oauth-authorize-freshness): gate items i, y, l, n and ak(1) (with ak(2)/(3)) are closed in the server by consent on every authorization (FR1), server-owned fail-closed freshness (FR2-FR4, FR14), the missing-IdP-refresh-token check at the callback (FR13), the per-device IdP refresh lease (FR15) and the null cross-signing key normalization (FR16); the epic SEC gate E-2 "(i)/(y) sharpened" is closed with them (section "Consent, freshness and refresh serialization"). Accepted risk until the legacy shutdown: the legacy `m.login.sso` login (`/_matrix/client/v3/login/sso/redirect`) has no consent screen. `oauth_enabled` stays false: see the activation checklist in `docs/architecture/07-deployment.md`.

## Consent, freshness and refresh serialization (story oauth-authorize-freshness)

Closes gate items i, y, l, n and ak(1)-(3) and the epic SEC gate E-2 "(i)/(y) sharpened" (decisions FR1-FR21). Before this story
`Authorize.issue_code/5` minted a code right after provisioning: no freshness, consent or device-holder
check, and `auth_time` fell back to `iat`. Dex reportedly omits `auth_time` and ignores `max_age` (oracle
O5), so `login_required` on unproven freshness would lock Dex users out, and freshness alone does not stop
E-2 (a user who logs in after following the link still authorizes the attacker's app). Decisions (prefix
`FR`):

- **FR1 Consent on EVERY authorization (safe variant).** A server-rendered consent screen is shown after
  the verified IdP login and provisioning, before any code exists; no remembered grants, no skip, not even
  with a fresh `auth_time`. RFC 6749 10.2 and RFC 8252 8.6 forbid automatic processing for clients the AS
  cannot authenticate (all Matrix clients are public; loopback / private-use redirects are
  unattributable); a fresh IdP login proves presence, not which app (the IdP page names only Nebu); Matrix
  v1.15 "Scope" encourages consent; remembered consent needs a table plus a lifecycle (revocation, scope
  changes), each a fail-open risk (follow-up av). Cost: one click per interactive login (refreshes never
  use authorize). Supersedes D5 and A26.
- **FR2 Freshness helper.** `Nebu.OAuth.Freshness` (pure, extracted from `Nebu.OAuth.Account`):
  `auth_time(claims)` reads the `auth_time` claim ONLY (an integer; a float is truncated; everything else,
  `iat` included, is absent); `evaluate(t, requested_at)` is `{:fresh, min(t, now)}` when `t` is at most
  60 s older than `requested_at` (the clock skew), `{:stale, t}` when older, `:absent`.
- **FR3 No `login_required` for unproven freshness.** At the callback absent or stale freshness does not
  end the flow: it sets `login_fresh = false` and the consent page shows a notice. FR1 guarantees that no
  code exists without the user's click (the "or a consent screen" alternative of E-2, on by default with no
  switch). `login_required` stays for `prompt=none` only (D11), answered before the IdP and before consent;
  a client `max_age` stays ignored (D12), so the id_token may carry no `auth_time` and clients must not
  rely on it.
- **FR4 Stored `auth_time` = the raw claim or NULL.** `oauth_codes.auth_time`, `matrix_sessions.auth_time`
  and the id_token `auth_time` are `Freshness.auth_time(claims)` (clamped) or NULL; never `iat`, never the
  consent time (the raw claim, not a substitute). `IdToken` omits a nil `auth_time`.
- **FR5 Callback order.** Unchanged up to the IdP login (bucket, live, state, consume, binding,
  `recheck_client`, IdP error, verifier, IdP login); then (a) gate l (FR13) before any side effect, (b)
  provisioning (deactivated => `access_denied`), (c) freshness, (d) device holder (FR11), (e) encrypt the
  IdP refresh token, (f) the consent row, (g) `303 Location: /oauth2/consent` with the cookie.
  `CodeStore.insert` is called only by `Nebu.OAuth.Consent` (static test).
- **FR6 Consent state.** Table `oauth_consent_requests`, key `binding_hash` (SHA-256 hex of the 256-bit
  cookie), the inputs of the code plus `login_fresh` and the `source_key`, TTL at most 5 minutes (CHECK),
  soft caps inside the INSERT (`temporarily_unavailable`): 10 000 live rows overall, 5 per user and 20 per
  source (`Nebu.OAuth.SourceKey`, review L-2; nothing is evicted), consumed by ONE `DELETE ... RETURNING ...,
  (expires_at > now()) AS live`, purged by `OAuthFlowPurgeWorker`. Module `Nebu.OAuth.ConsentStore`.
- **FR7 Routes (PRG).** `GET /oauth2/consent` renders from the live row (no mutation, reload safe);
  `POST /oauth2/consent` decides; other methods `405` (`Allow: GET, POST`), sub-paths `404`. The live check
  comes before the bucket `{"oauth_consent", ip}` (600/h) and any DB access; no CORS; `JsonBody` skips the
  path (`FormPost.parse/1`).
- **FR8 Binding and CSRF.** Cookie `__Host-nebu_oauth_consent` (`Path=/; Secure`) on https, else
  `nebu_oauth_consent` (`Path=/oauth2/consent`); `HttpOnly; SameSite=Lax; Max-Age=300` (Strict would not be
  sent on the `303` after the IdP's cross-site chain). The CSRF token is the base64url SHA-256 of the
  cookie value with the fixed prefix `nebu-oauth-consent-csrf:`, constant-time compare, nothing stored. POST order, all before consumption: form
  parse, `Origin` (absent, the issuer origin, or `null` only with `Sec-Fetch-Site: same-origin`),
  `Sec-Fetch-Site` (absent / `same-origin`), navigation metadata (absent / `navigate`, `document`, `?1`),
  cookie, token. A failure is a `403 forbidden` page with ONE value-free WARNING and nothing consumed. The
  checks live in `Nebu.OAuth.BrowserPost`, one copy shared with the account page.
- **FR9 Page content.** `Nebu.OAuth.ConsentPage`, every value HTML-escaped: the signed-in user id, the
  claimed app name, the claimed website host labelled "claimed by the app, not verified by Nebu" (the
  unverified `client_uri` must not borrow the administrator's credibility, review L-5), the redirect target
  (an https host marked "part of the app website" when it is the `client_uri` host or a subdomain AND that
  site is a real registrable name, never a bare public suffix; an https destination that is NOT part of the
  claimed website gets an explicit warning block; "an app on this device" for loopback and private-use
  schemes, with a warning that Nebu cannot check which app receives it), the session line (FR11) and, when
  a session is replaced, its own warning block before the form (device name first), the full-access
  sentence, `tos_uri` / `policy_uri` as escaped plain text (no link) after it, the notice
  ("You were not asked for your password just now ...", a warning block with a text label, no live region:
  static text in a `role="status"` region is not announced reliably) for ANYTHING but an exactly fresh
  login (a missing value can never hide it), and the sentence "Only allow this if you just started signing
  in to this app yourself." A device name is cut at 80 characters. One form, two equal `submit` buttons
  (Deny first, Allow armed by FR21), no image, link or autofocus. The three warning blocks carry the ids
  `freshness-notice`, `destination-notice` and `replace-notice` and the destination `dd` is
  `consent-destination` (its `dt` is `consent-destination-label`); Allow is `aria-describedby` the hint, the
  destination label and value and exactly the rendered warning blocks (story consent-arming-hardening).
- **FR10 Headers.** `no-store`, `Pragma: no-cache`, `X-Frame-Options: DENY`, `Cross-Origin-Opener-Policy:
  same-origin` (FR21), `Referrer-Policy: same-origin` (`no-referrer` would make the page's own POST carry
  `Origin: null`), no CORS; CSP `default-src 'none'; style-src 'sha256-<css>'; script-src 'sha256-<script>'
  (FR21); img-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self' <target>`. Chromium applies `form-action` to the redirect that follows a form POST, so
  `<target>` is the redirect target of the row: the https origin; for a LOOPBACK redirect (`localhost`,
  `127.0.0.1`, `[::1]`) NO host source but the scheme source `http:` (an IPv6 literal such as `[::1]` is not
  a valid CSP host-source); for a private-use scheme the scheme source `<scheme>:`. The scheme is
  lower-cased and the source is built from parsed components only; when it cannot be built the answer is
  the `server_error` page with nothing consumed.
- **FR11 Device holder.** `Nebu.Matrix.oauth_device_holder(user_id, device_id)`: none => a new session;
  the same app => "continues your existing session"; a legacy or session-less device => "replaces your
  existing session ... will be signed out"; a live OAuth session of ANOTHER app => REFUSED (`403
  device_in_use` page, no row, no redirect). **Nebu policy, stricter than the spec** ("Relationship between
  access tokens and devices" and "Device ID allocation" only bound length and charset): a device id held by
  another app is never handed over; reason RFC 9700 4.11 and RFC 6749 10.12 (an approved but hostile client
  must not take over a victim's device). "Same app" survives DCR re-registration (the `client_id` changes
  with every metadata change): equal `client_id`, or equal deduped identity = the normalized `client_uri`
  plus the sorted, de-duplicated `redirect_uris` (`ClientStore.client_identity/1`); a client without a
  `client_uri` counts only with an equal `client_id`. Re-checked at Allow; `:unavailable` is
  `temporarily_unavailable` at the callback and a `503` page at Allow. Review L-1: the holder the user
  accepted is stored in the code (`oauth_codes.device_holder_checked` / `device_holder_client_id`) and
  re-checked when the code is redeemed, inside the issuance transaction under the `devices` row lock; a
  live OAuth session of another app than the redeeming client and the accepted holder is `invalid_grant`
  and nothing is issued (codes of older nodes carry no check).
- **FR12 POST outcomes.** No live row => `400 invalid_state` (the cookie is cleared except on `429`; "close
  this window and start signing in again from your app"). Both decisions answer `303 See Other` (never
  302/307): `deny` => `access_denied`, `allow` => client still `approved` (else the `403 client_rejected`
  page; a revoked client counts as rejected), FR11 again, then the code with `code`, `state`, `iss` in the
  row's response mode. Every `error_description` is fixed ASCII without `"` or `\`.
- **FR13 Gate l.** With `oauth_idp_revalidation = per_refresh` (also the fail-closed reading of an unknown
  or unreadable value) and no IdP refresh token, the callback answers `server_error` BEFORE provisioning,
  with a fixed description that names no configuration, and persists nothing; one WARNING per node per 10
  minutes tells the operator to set `matrix_oidc_refresh_mode=offline` or `oauth_idp_revalidation=off`. T6
  at the token endpoint stays.
- **FR14 Gate y: the account page must fail closed.** An absent `auth_time` gives an account session with
  `auth_time` NULL (migration 000045 drops NOT NULL): never fresh, one WARNING per hour per node; a stale
  one is still `reauth_failed`. On a NULL session the delete and reset pages show the notice
  `freshness_unavailable` WITHOUT a reauth link (it would loop) and the destructive POSTs answer `303` with
  it, changing nothing; viewing works. Without an IdP `auth_time` OAuth users cannot delete devices or
  approve key resets (follow-up aw, release note).
- **FR15 Gate n: per-device IdP refresh lease, not an advisory lock.** An advisory transaction lock would
  hold a pool connection and a transaction across the IdP HTTP call (pool exhaustion on a slow IdP). The
  lease is a row of `oauth_idp_refresh_leases` (PK `(user_id, device_id)`, CASCADE with the device, TTL 60 s:
  discovery, token endpoint and JWKS fetch, each up to ~10 s of `:httpc` connect plus request timeout, plus
  margin; at most 120 s by CHECK; no fencing token, follow-up az; a killed holder leaves its lease until the
  TTL, followers get `503` meanwhile), claimed by `INSERT ... ON CONFLICT DO
  UPDATE ... WHERE lease_until <= now()`, released in `after`. A follower polls every 100 ms for at most 5 s
  and re-resolves the refresh token: a changed active row is a replay WITHOUT an IdP call; a consumed token
  (`{:reused, _}`) while waiting is `503 {}` + `Retry-After: 2`, never revocation; an exhausted budget is
  the same `503`; a lease SQL error is `503` + `Retry-After: 5`. The holder re-resolves after the claim,
  so a previous holder's rotation is never redeemed twice. `off` takes no lease.
- **FR16 Gate ak(1)-(3).** `device_signing/upload` normalizes the keys before the guard, the digest and
  the merge, for every caller: an explicit `null` key is absent, a non-object key is `400 M_BAD_JSON`. A
  body with no key (`{}` or all null) while a master is stored is `400 M_MISSING_PARAM` without UIA for
  every caller (a Nebu choice; the legacy answer was `403`). The "unchanged" rule compares the supplied
  keys only. `replace_with_approval/7` re-reads the keys inside the transaction after consuming the
  approval with a locked read (`FOR UPDATE`; an error rolls back, `500`): since story cross-signing-upload-races
  `CrossSigningKeyStore.lock_keys/1` (the row lock, the `sync_global|` advisory lock, then the read; it replaced
  `get_keys_for_update/1`).
  The `Account` moduledoc names the `Origin: null` fallback and that the navigation check does not stop a
  scripted `form.submit()` (gate ag).
- **FR17 Logging.** INFO `OAuth callback: consent requested ...` and `OAuth consent: allowed|denied|refused
  ...` with ids only; never the cookie, CSRF token, code, state, nonce, verifier, claims, names or
  redirect URI. `/oauth2/consent` joins the names-only query paths of `RequestLogger`; its body is never
  captured.
- **FR18 No leak.** The client sees only `code` or a fixed-description `access_denied` / `server_error` /
  `temporarily_unavailable`; `device_in_use`, `invalid_state`, `forbidden` and `client_rejected` are user
  pages, never redirects.
- **FR19 Migration 000045.** `oauth_consent_requests` (grants `SELECT, INSERT, DELETE`, UPDATE revoked,
  RLS enabled and forced), `oauth_idp_refresh_leases` (four grants and policies, forced RLS) and
  `oauth_account_sessions.auth_time DROP NOT NULL`. Additive and rolling-deploy safe; the down migration
  deletes NULL sessions before restoring NOT NULL. No `server_config` change.
- **FR20 ADR-020.** The Matrix domain gains the facade `oauth_device_holder/2`; the lease lives in the
  Matrix domain (`OAuthSession`, `OAuthSessionStore`), `CrossSigningKeyStore.lock_keys/1` (formerly `get_keys_for_update/1`) is Matrix-internal. The
  OAuth domain never names a Matrix-internal module.
- **FR21 Double-clickjacking mitigation (security review M-1, amended by story consent-arming-hardening / G3-5; changes the earlier "no script" design).** An
  attacker page can open a window and navigate its opener to `/oauth2/authorize` with an approved attacker
  client and a victim device id, so that the consent page lands behind the victim's second click of a
  double click (a real, user-activated click: Origin, fetch metadata and CSRF all pass). The page therefore
  carries exactly ONE inline script, pinned by `script-src 'sha256-<hash of exactly that script>'` (no
  `'unsafe-inline'`, no other script source): `Nebu.Web.ArmScript.script()`, the shared, generic ES5 script
  of the SSO confirmation page (the button name in its live-region messages comes from the button's own text,
  so it says "Allow" here). Allow is rendered `aria-disabled="true"` (never `disabled`: it stays focusable
  and announced), with `data-arm` and a `form="oauth-consent-armed"` attribute that points at no form, so
  that without JavaScript Allow is inert and the implicit submission of the form is Deny (fail closed). It
  is armed only after REAL interaction elsewhere on the page (a pointer move of at least 4 px from the first
  position, a key press, a wheel event, a touch, a `focusin` on another element; a `scroll` event does not
  arm) AND at least 600 ms after load. After arming, a mouse / pen click is accepted only when a pointer
  movement of non-zero distance over Allow happened after the arming (the pointer must travel onto Allow, a
  pointer parked on the Allow position cannot decide; a layout shift under a parked pointer does not count),
  and a keyboard activation only when the focus moved onto Allow after the arming. A blocked activation is
  announced in the polite live region (`data-arm-status`); a visible hint (`data-arm-hint`) explains how Allow
  becomes available. Deny is never `aria-disabled` and comes first in the DOM and visual order. A
  `noscript` line says that Allow stays unavailable without JavaScript. `Cross-Origin-Opener-Policy:
  same-origin` severs the opener relationship of a window that lands on the page (this differs from the
  SSO confirmation page on purpose: web clients of this epic do not need an opener through the consent
  page). The server never trusts the button state (cookie, CSRF token and fetch metadata are checked as
  before): this is a usability barrier against an unintended click, not an authorization. Rejected: a
  confirmation dialog (also a click target for the same attack), a pure CSS delay (no input evidence), a
  `pointerenter` rule (a layout or scroll change under a parked pointer fires it too).
  G3-5 is REDUCED, not eliminated: it is closed in the server for the parked-pointer double-click and for
  multi-gesture lures with the pointer parked on Allow. **Accepted residuals:** (click game) a moving-target game
  whose click on target A opens the consent popup so that Allow sits where target B will be: the pointer then
  travels onto Allow like for a real user, and only the 600 ms dwell and the arming interaction remain; (touch) one touch elsewhere arms
  after 600 ms and a following tap on Allow is accepted, so a multi-tap lure with a known mobile layout can
  still land; (keyboard) a lure with pauses ("Tab, wait, Tab, Enter") can move the focus onto Allow after
  arming and press Enter; (popup clients) a web client that runs the OAuth flow in a popup loses
  `window.opener` at the consent page because of COOP (manual verification, follow-up `cr`). Follow-up
  `cp` covers touch and keyboard for both decision pages.

Accepted risk: the legacy `m.login.sso` login has no consent screen until the legacy shutdown (it never
issues an OAuth session). Open: remembered consent (av), revoked-client consent rows (ax), lease fencing (az). Closed: persist_single (au), by story
cross-signing-upload-races (2026-10-28: the signature merge reads its base under the per-user lock in one transaction).

### Manual verification (operator, before `oauth_enabled`)

Fail closed in code; verify and record (also in the story's Dev Agent Record):

1. **Dex v2.45.1:** is `auth_time` in the id_token, and is there a re-prompt on `max_age=0` / `prompt=login`?
   Without `auth_time` the consent notice must show and `/account` delete / reset must show
   `freshness_unavailable`.
2. **An IdP that emits `auth_time`** (Keycloak): no notice, and `/account` destructive actions work after reauth.
3. **Element Web** (Chrome, Firefox, Safari): login through consent; the `form-action` CSP must not block
   the post-Allow redirect; reload and the back button behave per FR7 / FR12.
4. **FluffyChat** (Android Custom Tab, iOS ASWebAuthenticationSession): the POST, then the `303` to the
   private-use scheme, reaches the app.
5. **Refresh race, scripted:** two parallel `POST /oauth2/token` refreshes of one refresh token
   (`per_refresh`) against Dex (`refreshTokens.reuseInterval`) and an IdP with reuse detection: no logout,
   one IdP redemption.
6. `per_refresh` with an IdP client that issues no refresh token: `server_error`, one WARNING in the admin log viewer.
7. The consent page in a cross-origin iframe is blocked; screen-reader pass.
8. Double clickjacking (FR21): from a test page, `window.open` a popup and navigate the opener to a consent
   URL while double-clicking at the Allow position: the second click must not decide. The multi-gesture
   variant (move the pointer and wait first, then click at the Allow position without a new movement) must
   not decide either; record the result. With JavaScript disabled Allow is inert and Deny works; a touch
   device (a tap elsewhere arms, then Allow) and a screen reader (VoiceOver / TalkBack touch exploration,
   Tab) can reach Allow, hear the hint and allow after arming (VoiceOver iOS / macOS, TalkBack, NVDA, JAWS; if it
   fails, an AT path in the script needs a security review). The moving-target "click game" variant is not covered. A popup-based web client through the
   consent page: record whether the login completes with COOP `same-origin` (D5, follow-up `cr`).

## Trusted-proxy client IP (phase 2, story oauth-trusted-proxy-client-ip)

Closes the server side of gate item 1 (Kassandra F-1) and the confirmations (a) of stories 2, 3 and 4. Before
this story every per-IP decision used the directly connected peer, which is nginx on both reference
deployments: one global bucket per tier. Decisions (prefix `TP`):

- **TP1 (config).** `NEBU_TRUSTED_PROXY_CIDRS`: IPv4 / IPv6 address literals with an optional `/prefix`,
  separated by `,` and/or whitespace; a bare address is `/32` or `/128`. Unset / empty = no trusted proxy
  (default, identical to the behaviour before the story, no log line). A NEW name on purpose: the legacy
  boolean `NEBU_TRUSTED_PROXY` was never read by the Elixir server and is not reused, so a stale `true`
  can never mean "trust everyone".
- **TP2 (fail-closed parsing).** An entry is ignored when it is not a strict address literal
  (`:inet.parse_strict_address/1`: no `10.1` shorthand), has a leading-zero IPv4 octet, carries a zone, port
  or brackets, has a prefix outside `0..32` / `0..128`, has host bits set (rejected, not masked), is an
  IPv4-mapped IPv6 entry or is a keyword (`*`, `all`, `true`, `0/0`). More than 64 entries or 4096 bytes
  ignore the whole variable. One boot warning names the count and at most 5 entries (each cut to 64 bytes);
  there is never a trust-all fallback.
- **TP3 (explicit catch-all).** `0.0.0.0/0` or `::/0` written literally is accepted but logs one loud boot
  warning (any client that reaches Nebu directly can choose its rate-limit bucket). A valid set logs one info
  line with the count, not the list.
- **TP4 (when the header is honoured).** Only when the normalised direct peer is in the trusted set;
  otherwise every forwarding header is ignored (spoof refused).
- **TP5 (algorithm).** All `X-Forwarded-For` lines are joined and walked right-to-left; each element must be
  an IP literal, a trusted element is skipped, the first (rightmost untrusted) element is the client.
  Elements left of it are never parsed. Fallback to the direct peer (never the leftmost element) when the
  header is absent or empty, an element reached by the walk is empty or malformed, every element is trusted,
  the joined value exceeds 2048 bytes (checked before splitting) or more than 20 elements would be examined.
- **TP6 (`Forwarded` and `X-Real-IP` ignored).** RFC 7239 `Forwarded` and `X-Real-IP` are ignored entirely,
  also when `X-Forwarded-For` is absent (adds attack surface; on UpCloud `alb` the real-ip value is the LB).
- **TP7 (normalisation).** IPv4-mapped IPv6 is converted to IPv4 before matching and in the result; a family
  never matches the other family. The string is `:inet.ntoa/1` of the normalised tuple, byte-identical to the
  previous string for IPv4 and native IPv6 peers (`get/1`; rate-limit keys see TP8).
- **TP8 (bucket semantics).** Tags, rates and key shapes are unchanged, only the IP string changes; the
  RateLimit plug keeps its shared bare-string key across tiers. Security review cycle 1: rate-limit keys use
  `Nebu.Web.ClientIP.bucket/1`: IPv4 unchanged, a native IPv6 client is aggregated to its /64 network
  (`2001:db8:1:2::/64`), because one routed /64 gives a client 2^64 addresses and per-address keys would mint
  unlimited buckets. Stored data (`devices.last_seen_ip`, `oauth_clients.created_from_ip`) keeps the exact
  `get/1` address. Idle buckets are evicted per node by `Nebu.Web.RateLimitSweeper` (every 10 minutes, rows
  idle > 1 hour; every bucket refills within an hour, so eviction grants no extra budget).
- **TP9 (one resolution point).** `Nebu.Web.Plugs.ClientIP` sits in `Nebu.Web.Router` right after
  `RequestId` and stores `conn.private[:nebu_client_ip]` and `[:nebu_client_ip_source]` (`:peer | :forwarded`);
  `conn.remote_ip` is NOT overwritten, so nothing can re-resolve a rewritten value. A contract test scans
  `server/lib` so that only the two `client_ip.ex` files read the peer or `X-Forwarded-For`.
- **TP10 (the helper).** `Nebu.Web.ClientIP.get/1` returns the private value, or for a conn that never
  passed the plug the normalised direct peer, never a header-derived value (a path that bypasses the plug can
  never be spoofed). All consumers call it; the duplicated `ip_string` / `client_ip` / `ip_key` copies are deleted.
- **TP11 (multi-node).** The resolution is a pure function of request and env; the parsed list is cached in
  `:persistent_term` at boot (identical on nodes with the same env). The buckets stay node-local ETS.
- **TP12 (`RequestScheme` unchanged).** `X-Forwarded-Proto` / the `Secure` cookie flag are NOT gated by the
  list (would flip cookie names on running deployments); non-gating follow-up.
- **TP13 (no IP in logs).** The plug logs nothing per request EXCEPT one throttled WARNING per node and 10
  minutes when an untrusted peer sends `X-Forwarded-For` (story client-ip-misconfiguration-warnings, W1; a
  node-local `:atomics` slot, not the rate limiter); no line ever carries an address or a header value. Boot
  lines never print resolved addresses.
- **TP14 (topology is the operator's job).** Nebu cannot detect a wrong list. An empty or invalid list is safe
  (shared buckets), a too-broad one is not: trusting a network from which untrusted clients can connect re-opens
  spoofing. Trust the pinned nginx address as a /32 (not the compose subnet, which also holds the Docker
  gateway and other containers); bind the published ports `8008` / `8080` to `127.0.0.1` before trusting the
  Docker gateway (with default iptables DNAT an external IPv4 client keeps its source address, but host
  loopback, IPv6 clients reaching an IPv4-only bridge and rootless / Desktop Docker arrive from the gateway);
  list a load balancer only if it was verified to APPEND (or overwrite with) the client address.
  Template changes (setting the variable, loopback-bound ports, pinned compose subnets) are done by story P5
  (gate m): the templates pin `compose_subnet` (default `172.30.0.0/24`, nginx proxy container `.10`, gateway `.1`)
  and trust `<.10>/32` (`alb`) or `<.1>/32` (`acme`, ports bound to `127.0.0.1:8008` / `127.0.0.1:8080`), nothing for
  `none` (public `8008`, no trusted proxy); `trusted_proxy_cidrs` overrides. An LB hop is never listed in Nebu's list;
  the optional `lb_real_ip_cidrs` makes nginx (not Nebu) resolve the client from the LB's `X-Forwarded-For` on the
  `:8081` listener only, and only after the LB was verified to APPEND (no safe default). Residual (accepted, follow-up ap4): an oversized, over-hop or malformed header behind a trusted proxy
  falls back to the proxy bucket.
  Nebu warns where a misconfiguration is reliably visible (story client-ip-misconfiguration-warnings: W1 a
  request with `X-Forwarded-For` from an untrusted peer, W2 a periodic WARNING when at least 10 active devices
  of at least 5 users were all seen from at most 2 addresses, W3 an OpenTofu `check` warning in the reference
  templates for `alb` / `dynamic` with an empty `lb_real_ip_cidrs` and for the UpCloud TCP-mode frontends) but
  cannot detect a wrong list in general: the collapsed address (the LB or proxy address) is indistinguishable
  from a legitimate intranet client, W1 is ambiguous (a client can write the header itself) and W2 is
  statistical (a single NAT looks the same). Their absence proves nothing; activation is never blocked in code
  and the POSITIVE client-IP test stays a manual, gating precondition (G3-2).

### Manual verification (operator, before `oauth_enabled`)

| Deployment | Path | Expected XFF at Nebu / peer | CIDRs to trust | Status |
|---|---|---|---|---|
| UpCloud `alb` / `dynamic` | client -> UpCloud LB (HTTP mode, `set_forwarded_headers`) -> compose nginx `:8081` (plain-HTTP frontend: LB redirect, nginx `:80` fallback without realip) -> `server:4000` | `<client>, <LB private IP>` if the LB adds XFF, else only the LB IP; nginx overwrites XFF with its own `$remote_addr` (or, with `lb_real_ip_cidrs`, with the resolved client); peer at Nebu = nginx container IP | template-set: pinned nginx container IP /32 (`<compose_subnet>.10`) in `NEBU_TRUSTED_PROXY_CIDRS`; the LB network CIDR ONLY IF the LB was verified to APPEND (or overwrite with) the client address, else do not list it and accept the LB-shared bucket; `lb_real_ip_cidrs` (exact LB /32, nginx realip on `:8081` only) is the verified-append switch, empty by default | VERIFY that the UpCloud LB appends / overwrites `X-Forwarded-For` (a forwarding-only LB lets a client write the key; if no client address arrives the client IP is unrecoverable) and the LB source address; negative test over `https://` AND `http://` port 80 |
| UpCloud `acme` | LB TCP passthrough -> host nginx (TLS) -> `127.0.0.1:8008` | nginx `$remote_addr` = LB private IP (no PROXY protocol); peer = docker gateway | template-set: docker gateway /32 (`<compose_subnet>.1`), ports bound to `127.0.0.1:8008` / `127.0.0.1:8080`; no client IP behind the TCP LB | client IP lost at the LB: not supported without PROXY protocol (follow-up) |
| UpCloud `none` | LB TCP -> `server:8008` | no XFF; peer = LB | none (template sets no trusted proxy; `trusted_proxy_cidrs` is refused) | not supported |
| Stackit `alb` | Stackit ALB (HTTPS 443 -> pool `matrix-api` VM `8081`; HTTP 80 -> pool `matrix-api-http` VM `80`, nginx redirect) -> compose nginx -> `server:4000` | as UpCloud `alb` | template-set: pinned nginx container IP /32; the ALB network CIDR ONLY IF the ALB was verified to APPEND (or overwrite with) the client address, else do not list it; `lb_real_ip_cidrs` as for UpCloud `alb` | VERIFY ALB XFF behaviour (append / overwrite, not forward-only), the ALB source address and the negative test over both listeners |
| Stackit `acme` | (NLB?) -> host nginx -> `127.0.0.1:8008` | `<client>` if the NLB preserves the source IP; peer = docker gateway | template-set: docker gateway /32 (`<compose_subnet>.1`); valid only because `8008` / `8080` are bound to `127.0.0.1` and unreachable from outside (Stackit `acme` is `127.0.0.1`-bound in the template) | VERIFY source-IP preservation (Stackit NLB) and port exposure |

Checks: count the real hops (`tcpdump` or a temporary nginx `log_format` with `$http_x_forwarded_for` and
`$remote_addr`), `docker network inspect` for the nginx address (random unless pinned, P5), confirm
`8008` / `8080` are not reachable from the internet, then two clients from different networks must show
different `last_seen_ip` values and independent `429`s on `/login`. NEGATIVE test: send `X-Forwarded-For:
203.0.113.99` through the public endpoint over IPv4 and over IPv6 and directly to `:8008` / `:8080` if
reachable; `last_seen_ip` must never show `203.0.113.99` (otherwise the LB or a listed network lets clients
write the header: remove it from the list). Operator documentation:
`docs/architecture/07-deployment.md` "Client IP behind a reverse proxy".

## DCR and flow-state abuse hardening (phase 2, story oauth-dcr-abuse-hardening)

Closes the server side of gate items 2 (bulk removal), 3 (public suffix), 4 (N-1) and (h) (per-source live
authorization cap), and (aa) for login requests. Depends on story oauth-trusted-proxy-client-ip: the client
address is ALWAYS `Nebu.Web.ClientIP.get/1`. Decisions (prefix `AH`):

- **AH1 (gate 4 / N-1: key = (registrable domain, source); REFUSE, never evict).** `oauth_pending_host_cap`
  (default 20, name kept) counts pending rows with the same `client_domain` (AH6) AND `source_key` (AH3);
  above it the unchanged `503 temporarily_unavailable` + `Retry-After`. Rejected: evicting the oldest row
  of the host lets an unauthenticated registrant delete rows of a DIFFERENT source (a legitimate row could
  vanish right before approval); evicting within the same (domain, source) churns rows under the admin's
  hands and gains nothing once the source is in the key. Element Web registers from each user's browser,
  so the real client has another source than the attacker, who only fills its own slots. Residual: an
  attacker sharing the source (same NAT or /64) can fill that source's slots; recovery is the bulk removal
  by domain (AH8). Dedup hits stay uncapped.
- **AH2 (per-source total cap, global cap kept).** At most 100 pending rows per `source_key` over all
  domains (built-in); filling the global `oauth_pending_cap` (5000, unchanged) needs at least 50 sources.
  All counts are conditions of the ONE INSERT (READ COMMITTED overshoot <= N-1, as before).
- **AH3 (source key).** `Nebu.OAuth.SourceKey`: IPv4 => `v4:a.b.c.d`; IPv6 => `v6:` + the first 64 bits
  (per /64); IPv4-mapped => IPv4; unparseable (the resolver's fail-closed fallback) => `raw:` + input
  truncated to 64 bytes. Key = lowercase hex SHA-256 of `nebu-oauth-source-v1|` + that string: a
  fixed-length grouping key, pseudonymous, not anonymous (IPv4 is enumerable). Deliberately not keyed
  with the internal secret (per-purpose subkeys are follow-up (aq)); exposure is bounded (pending rows
  already hold the clear IP, authz/login rows live at most 10 minutes, decided rows carry no key, AH7).
  Never logged.
- **AH4 (public-suffix list: built-in, no network).** `Nebu.OAuth.PublicSuffix` holds two compile-time sets
  of hand-picked names (not a copy of the Mozilla list). `:icann`: `co.uk org.uk ac.uk gov.uk me.uk ltd.uk
  plc.uk net.uk com.au net.au org.au edu.au gov.au co.nz org.nz co.jp ne.jp or.jp com.br net.br org.br
  gov.br edu.br com.cn com.mx co.za co.in com.tr com.sg co.kr com.tw com.hk com.ar co.il org.il ac.il
  gov.il net.il muni.il com.pl net.pl org.pl co.th ac.th or.th go.th in.th net.th co.id ac.id or.id go.id
  web.id com.ua net.ua org.ua gov.ua com.ph com.pk com.eg com.sa com.my com.vn com.ng co.ke com.co com.pe
  co.at or.at`. `:private` (multi-tenant hosting): `github.io githubusercontent.com gitlab.io bitbucket.io
  vercel.app now.sh netlify.app herokuapp.com pages.dev workers.dev trycloudflare.com azurewebsites.net
  azurestaticapps.net cloudapp.net blogspot.com appspot.com web.app firebaseapp.com fly.dev onrender.com
  glitch.me surge.sh readthedocs.io ngrok.io ngrok-free.app ngrok.app s3.amazonaws.com cloudfront.net
  amplifyapp.com duckdns.org wordpress.com wixsite.com myshopify.com r2.dev deno.dev up.railway.app
  loca.lt elasticbeanstalk.com cloudapp.azure.com github.dev`. No wildcard or exception rules. The LONGEST
  listed suffix equal to the host or a dot-suffix of it wins; none => the last label. Registrable domain =
  suffix + one label. Extending: add the lowercase suffix to the right set, a test row and this list. A
  missing platform (for example the regional `s3.<region>.amazonaws.com` names) only means coarser
  grouping (harmless with the source in the key) and no badge; vendoring the full list is follow-up (ar).
- **AH5 (a `client_uri` host that IS a public suffix is refused).** `400 invalid_client_metadata`
  ("client_uri must not be a public suffix such as github.io; use your own site, e.g. name.github.io").
  Closes the root of the `*.github.io` hole (redirect, logo, tos, policy hosts and private-use schemes
  all derive from the client host). Validation precedes dedup, so a re-registration of an existing
  suffix-host row also gets 400 (none in a release; fail closed). `name.github.io` is accepted with a
  badge (AH7).
- **AH6 (registrable domain stored, not trigger-guarded).** `oauth_clients.client_domain`, set at
  registration (from `Registration.validate/1`, else derived from `client_uri`). It only drives the
  pending-row caps and is NOT added to the 000040 guard trigger (that would re-state 000040's function
  body; a runtime-role SQL bug rewriting it gains nothing). Rows from before migration 000044 keep NULL
  and count only globally (unreleased, they age out).
- **AH7 (minimisation and badges).** `source_key` exists only on pending rows: approve and reject set it
  to NULL together with `created_from_ip` / `user_agent`; the CHECK `oauth_clients_source_key_pending_check`
  (`status = 'pending' OR source_key IS NULL`) pins it. The approval page derives its badges from the
  host at render time through `Nebu.OAuth.host_info/1` (ADR-020): "shared hosting domain (github.io):
  anyone can create sites here" (warning) and "client URI host is a public suffix" (error, legacy rows).
- **AH8 (bulk = DELETE of pending rows, not "reject").** The RLS policy `oauth_clients_delete_pending`
  (000040) already allows it for the runtime role: no RLS change. Not a bulk `rejected`: a rejection is
  FINAL (guard trigger, N-3), so one wrong bulk click would permanently block a legitimate client's
  metadata, and rejected rows are never purged. A deleted legitimate registration re-appears as pending
  on the next flow. Per-row Reject is unchanged. UI wording: "Remove pending registrations".
- **AH9 (criteria, preview, snapshot, bounds, audit).** Criteria are AND-combined, at least one: `host` +
  `match` (`exact`, or `domain` = the registrable domain of the input and all its subdomains, plain
  string comparison, never `LIKE`; also matches pre-000044 rows) and `older_than_days` (1..3650). The host
  input is trimmed, lower-cased and checked with the registration's LDH rule; `domain` on a public suffix
  is refused. GET = read-only preview (count, first 20 rows, snapshot `as_of`, the database clock); POST removes
  only rows with `created_at <= as_of` (later registrations are never swept) and refuses an `as_of` that
  is missing, in the future or older than one hour ("preview expired"). At most 500 rows per POST
  (`ORDER BY created_at LIMIT 500 FOR UPDATE SKIP LOCKED`, the outer `status = 'pending'` re-check as in the
  purge); more => "500 removed, N still match. Run the removal again." ONE transaction: DELETE + ONE audit
  row `oauth_clients_bulk_removed` (target_type `oauth_client`, target_id `bulk`, metadata `criteria`,
  `as_of`, `removed`, `client_ids`; no client metadata); an audit failure rolls the removal back (the
  decision contract of the approval page). Zero matches => no delete, no audit row. The action is in
  `AuditWriter`'s `@known_actions`. HTML only, CSRF, admin only; the confirmation is the native
  `data-confirm`.
- **AH10 (gate h).** `oauth_authz_requests.source_key`; the INSERT also requires fewer than 300 live rows
  of the same source (`expires_at > now()`): the "smaller burst" (300 live rows instead of the 600 the rate
  burst allows; raised from 50 in review cycle 1: /authorize is a mandatory unauthenticated step of
  every login). The global 10 000 stays as a memory bound (filling it needs at least 34 sources).
  Never evict: `{:error, :capacity}` => the existing `temporarily_unavailable` redirect. Rows without a source
  never count per source (rolling deploy). The rate bucket `{"oauth_authorize", ip}` is unchanged.
- **AH11 (aa).** The same column and cap of 300 on `oauth_account_login_requests`, same `unavailable`
  answer. Account SESSIONS need no per-source cap (authenticated, 20 per user): (aa) is closed with that
  rationale.
- **AH12 (caps independent of the proxy config).** Behind nginx WITHOUT `NEBU_TRUSTED_PROXY_CIDRS` all
  clients share one source: the per-source caps become small GLOBAL caps (consent 20 per source, 300 in-flight logins, 100 pending
  registrations). An availability failure, never a security gap; the activation checklist makes "trusted
  proxy configured and verified" a precondition of the effect of items 4 and h.
- **AH13 (no `server_config` key).** Constants plus test seams. Re-creating `config_update_mutable` in
  parallel migrations risks losing keys. `oauth_pending_host_cap` keeps name and range; its meaning
  changed (AH1).
- **AH14 (residuals, non-gating follow-ups ao, ap, aq).** A /48 holder owns 65 536 /64 sources (coarser
  tier); the per-IP rate buckets stay per full IPv6 address (P1); a keyed source hash.
- **AH15 (logging).** No line carries a source key, IP, client host or registrable domain. The cap-hit
  lines stay ("global or per source"). Bulk: `OAuth admin: bulk removal removed=<n> actor=<admin id>`.
- **AH16 (cluster safety).** Caps are conditions of one INSERT; the bulk removal is one `SKIP LOCKED`
  statement in one transaction; the suffix list is compile-time data; no node-local state, no advisory
  lock.
- **AH17 (rolling deploy).** Migration 000044 adds only nullable columns, CHECKs that existing rows
  satisfy and indexes; no grant, policy, trigger or `server_config` change. Old nodes insert NULL sources,
  which never count per source. One exception, failing closed: while an OLD node still runs, its
  approve/reject of a pending registration that a NEW node registered (it carries a `source_key`) violates
  `oauth_clients_source_key_pending_check`, because the old SQL does not set the key to NULL; the decision
  fails with an error, nothing changes, and repeating it on a new node succeeds.
- **AH18 (review cycle 1).** The bulk snapshot `as_of` and its 1 h / future window use the DATABASE clock
  (`created_at` is a database timestamp). The audit row records the effective registrable domain next to
  the host as typed. The pending-cap counts avoid `IS NOT DISTINCT FROM` so the partial btree index stays
  usable. A refusal by a PER-SOURCE cap on authorize / account login is told apart from the global cap and
  logged as ONE throttled line per node and minute without address, key, host or client id (operators:
  if every client hits it, check `NEBU_TRUSTED_PROXY_CIDRS`, AH12); configuring the caps through
  `server_config` is follow-up (as), a /48 tier follow-up (at).

### Manual verification (operator, with `NEBU_TRUSTED_PROXY_CIDRS` verified)

1. Client A registers 20 new metadata for one test host through the public URL: the 21st answers `503`;
   client B on another network registers new metadata for the same host: `201`.
2. Real browser: badges for a `*.github.io` registration; bulk removal by domain and by age; native
   confirm; toast; one `oauth_clients_bulk_removed` row in the `/admin` audit log; keyboard-only and
   screen-reader pass on the preview page.
3. Element Web with the real IdP: after 300 abandoned authorize requests from another network, a real
   login still succeeds.

## Client revocation and same-origin hardening (story oauth-client-revocation)

Phase-2 story P4 closes the gates aj (E-1: an approved client can never be withdrawn) and ag including
"(ag) extended" (E-3: a same-origin script approving a client or a cross-signing reset). `oauth_enabled`
stays off by default; no Matrix CS API change.

### Client revocation (CR1-CR12)

- **CR1 (status `revoked`, migration 000046).** `oauth_clients` gains `revoked_by`, `revoked_at`,
  `revoked_reason` (<= 500 characters, only on a revoked row). The decision CHECK is re-created: pending =
  every decision column NULL; approved = `approved_*` set, `rejected_*` / `revoked_*` NULL; rejected = the
  000040 shape and `revoked_*` NULL; revoked = `approved_*` set (it WAS approved, the attribution is kept),
  `revoked_by` / `revoked_at` set, `rejected_*` NULL.
- **CR2 (guard trigger: approved -> revoked is the ONLY new transition).** `oauth_clients_guard_status()` keeps
  every 000040 rule and allows exactly `OLD.status = 'approved' AND NEW.status = 'revoked'` with the approval
  untouched and `revoked_by` / `revoked_at` set. Everything else on a decided row stays `check_violation`
  (revoked to anything, re-attribution or reason edit, approved -> rejected) and an explicit rule refuses
  `pending -> revoked` and `rejected -> revoked`: the generic CHECK alone would accept a revoked-shaped row, so a
  registration could skip the admin approval. Identity / metadata immutability is unchanged; the function is
  not SECURITY DEFINER and reads no other table.
- **CR3 (RLS unchanged, FORCEd).** The DELETE policy stays `status = 'pending'`: a revoked row is never
  deleted, so it keeps its metadata hash occupied. The INSERT policy additionally requires `revoked_* IS NULL`.
  `config_update_mutable` is not touched (other migrations re-create it).
- **CR4 (one transaction, lock order oauth_clients -> devices -> matrix_sessions).**
  `Nebu.OAuth.revoke_client/3` (`ClientStore.revoke/3`, timeout 120 s): (1) `UPDATE oauth_clients ... WHERE
  status = 'approved'` (0 rows: `:not_approved`); (2) the facade `Nebu.Matrix.oauth_end_client_sessions/2`, INSIDE
  the same transaction: the `(user_id, device_id)` pairs with a session row of the client, each torn down by the
  existing locked teardown (`devices` row `FOR UPDATE`, every session row of the device, the device tables with
  the E2EE keys), then a count that must be 0; (3) `oauth_codes.used_at` of the unused codes (the only UPDATE
  the 000041 guard allows); (4) DELETE of the client's `oauth_authz_requests` and `oauth_consent_requests` (the
  FK cascades only a client DELETE, which never happens to a revoked row; the callback and Allow then answer
  `invalid_state`; a consent row that slips in afterwards is refused at GET and Allow with `403 client_rejected`);
  (5) the caller's audit function: a failed audit (or a raise) rolls everything back. `oauth_idp_refresh_leases`
  die with the devices (FK cascade). After the COMMIT `Nebu.Matrix.oauth_after_device_teardown/1` (JWT denylist
  and binding deletion, legacy per-device cleanup) runs best effort, as for `/oauth2/revoke`. The nested
  transactions join the outer one only with the same repo module: the facade refuses a different repo.
  **Lock order caveat (review cycle 1, m2):** the order client -> devices -> sessions is consistent for
  issuance, rotation, `/oauth2/revoke`, the per-device teardowns and this revoke, but two older paths delete
  `matrix_sessions` rows of SEVERAL devices without the devices lock (`MatrixSessionStore.delete_for_user/1`,
  account deactivation, and `OAuthSessionStore.delete_by_code_hash/1`, code reuse): against them PostgreSQL may
  choose the revoke as a deadlock victim (SQLSTATE 40P01). The whole transaction is rolled back, so
  `ClientStore.revoke/3` retries it ONCE on a deadlock (logged without detail) and then reports the error.
  **Cross-client note (i1):** a device id is shared by every client of a user, so a revoke of client A can end a
  device that a re-login of client B took over between the pair listing and the teardown lock (the teardown
  deletes every row of the device, any client); the user simply signs in again on B.
- **CR5 (issuance and rotation lock the client row `FOR SHARE` first).** `OAuthSessionStore.insert_replacing_device/1`
  and `rotate/1` run `SELECT status FROM oauth_clients WHERE client_id = $1 FOR SHARE` as the FIRST statement
  of their transaction and roll back `:client_not_approved` unless the status is `approved`. `FOR SHARE`
  conflicts with the revoke's status UPDATE: either the issuance commits first and the revoke's teardown (a new
  statement, a new snapshot) deletes the new session, or the revoke commits first and the issuance re-reads
  `revoked`. One lock order everywhere (client, then devices, then sessions): no deadlock. **ADR-020 note:** this
  is the one cross-table read of the Matrix store; the SQL stays inline there (ADR-018) and reads one OAuth
  column, the same coupling the 000042 foreign key already has. `oauth_issue_session/1` gains
  `{:error, :client_not_approved}`; `oauth_refresh_session/4` maps it to `{:error, :invalid_grant}`. **Bounded
  wait (review cycle 1, Kassandra M-2):** the `FOR SHARE` runs under `SET LOCAL lock_timeout = '2s'` (reset right
  after the lock); a timeout rolls back as `:client_locked`, answered as `unavailable` (503 + `Retry-After`, no
  `error` member: a refresh simply retries, the client is not logged out; a code grant has already spent its code, so the client restarts the authorization, as for any other transient issuance failure). Without the bound a long revoke would park every
  token and refresh request of that client on a pool connection (pool 10) and turn into a server-wide 503.
- **CR6 (every entry point refuses `revoked`; nothing resurrects it).** Authorize: `403 client_rejected`, no
  redirect; the callback `invalid_state` (the request row is gone). Token: `401 invalid_client` at the lookup,
  `400 invalid_grant` when the revocation overtakes the issuance or the rotation. `/oauth2/revoke` answers `200
  {}` byte-identical to an unknown token; the resource server `401 M_UNKNOWN_TOKEN`. DCR with identical metadata
  maps to the revoked row (`201`, the same `client_id`, like a rejected dedup hit; no new row, no audit, never
  pending or approved again). A client that wants back registers CHANGED metadata (a new hash and a new
  approval): a revocation is final for that metadata; owner-level DDL is the only override.
- **CR7 (admin UI).** `Nebu.Admin.OAuthClientsController`: `GET /admin/oauth/clients` (approved, newest approval
  first, 50 per page: claimed name labelled unverified, verified `client_host`, type, approved by / at,
  `last_used_at`, live session count through the Matrix facade (`?` when unreadable, never `0`)), `GET
  /admin/oauth/clients/revoked`, the confirm page `GET /admin/oauth/clients/:client_id/revoke` and the POST. The
  sidebar group "OAuth" gains "Approved Clients" and "Revoked Clients".
- **CR8 (confirm step = typed host).** The confirm page names the client, the verified host, the device count and
  the consequences (sessions end, devices and E2EE keys are deleted, never re-approvable with this metadata). The
  POST needs `confirm_host` equal (trimmed, case-insensitive) to `client_host` (the client id when no host is
  stored) and takes an optional `reason` (the reject-reason normalisation, `Nebu.OAuth.normalize_reason/1`, at most
  500). A mismatch redirects back, nothing changed. It stops misclicks, not a same-origin script (it can read the
  host, SO7).
- **CR9 (audit).** `oauth_client_revoked` (target_type `oauth_client`, target_id the client id, metadata
  `devices`, `reauth` (`auth_time` | `flow` | `rpc`) and optionally `reason`; never client metadata or user /
  device ids) inside the revoke transaction. The approve audit metadata gains `reauth`.
- **CR10 (operator RPC).** `Nebu.Release.revoke_oauth_client/2` (the same function, actor `operator:rpc`,
  `reauth: "rpc"`) and `Nebu.Release.revoke_all_oauth_sessions/0` (every OAuth device, batches of 500, each through
  the locked per-device teardown; clients stay approved; legacy untouched; ONE audit row
  `oauth_sessions_revoked_all`; run after the switch-off) over `bin/nebu rpc` in the running node: shell access is
  the operator authentication and the escape hatch when the admin IdP is down. No UI for revoke-all (follow-up bc).
- **CR11 (scale).** One transaction per client with a 120 s timeout; a timeout rolls back completely and can
  be retried. Tested with 200 devices. While the transaction runs, the client row and every torn-down `devices` row stay locked, and every request
  that waits on them is bounded PER REQUEST (bugfix revoke-lock-bounds, finding G3-1 of the epic SEC gate 3, review
  cycle 1): `lock_client!` (issuance, rotation), the `per_refresh` IdP lease claim (an INSERT whose FK check takes
  KEY SHARE on the `devices` row, before `lock_client!` is reached) and its release run under `SET LOCAL
  lock_timeout = '300ms'` and answer 503 + `Retry-After` (5 for the lease), without consuming the refresh token (no
  IdP call, no transaction across the IdP leg); the request-path teardowns (`/oauth2/revoke`, `/logout`,
  `/logout/all`, account page) lock the device bounded (`bounded?: true`, 503 / 500) while the revoke's own teardown
  stays unbounded (`bounded?: false`); the `/sync` last-seen update (`FOR NO KEY UPDATE SKIP LOCKED`) and the
  pending-grace update of `mark_access_token_used/1` (`FOR UPDATE SKIP LOCKED`) skip locked rows instead of
  waiting for Ecto's 15 s query timeout. "Bounded" means each request holds a pool connection for at most 300 ms:
  the overall load is proportional to the number of the client's active devices that retry, so a very large revoke
  can still degrade the node while it runs; the full fix is follow-up bb. No role-level `lock_timeout` (it would
  also bound advisory locks and teardown). The audit of the other `devices` writers is in the bugfix's Dev Agent
  Record and follow-up bx. The admin
  request waits (behind nginx's 60 s read timeout the page may show a gateway error although the revoke
  succeeds; reload the list). A client with more than roughly 10 000 devices can reach the 120 s timeout and then
  cannot be revoked through this path at all: the two-phase revoke (a short transaction for status, codes,
  requests, consents and audit, then batched device teardown) is NOT part of this story and stays follow-up bb
  (the rpc function has the same limit). The post-commit work (JWT denylist, legacy session cleanup per device)
  also runs inside the admin request.
- **CR12 (logging).** `OAuth admin: client revoked client_id=<id> devices=<n>`; a WARNING with the error TYPE only
  on a rollback; never the reason text, the host, a token or a client metadata value. Phoenix parameter logging
  filters `reason`, `confirm_host` and `_csrf_token`.

### Same-origin hardening (SO1-SO8)

- **SO1 (code hardening now, separate origin recommended).** Code cannot enforce a separate origin (the issuer,
  `/account` and `/admin/callback` derive from the public host). The code side ships safe defaults (SO2-SO6); the
  deployment side is documented (SO8); the operator acknowledges SO7 before `oauth_enabled`.
- **SO2 (strict fetch metadata on the approvals).** There is ONE copy of the checks, `Nebu.OAuth.BrowserPost`
  (story oauth-authorize-freshness moved it there): `check/3` with `strict: true` (the Origin rules plus all four
  headers `Sec-Fetch-Site: same-origin`, `-Mode: navigate`, `-Dest: document`, `-User: ?1`, each exactly once and
  ABSENT refused, except the Safari rule of SO9 below) for `POST /account/cross_signing_reset/approve`, and `check_fetch_metadata/2` (`:strict` for the
  admin approve and revoke AND, since review cycle 1 (Kassandra L-2: a scripted POST must not reject, a rejection
  is final for that metadata hash), the admin reject and bulk removal, which need no marker; `:lenient` (absent
  allowed, a present header must have the strict value) remains for the consent / account forms; no Origin
  comparison) for the admin controllers. Refusal: the admin `403` page
  `fetch_metadata`, the account `403 forbidden`; a WARNING naming the failed header NAMES only. Order of checks:
  `require_admin`, Phoenix CSRF, fetch metadata, the fresh marker (SO4, approve and revoke only), the typed host
  (CR8), the decision.
- **SO3 (no JavaScript in the approval path; since story safari-fetch-metadata-compat one pinned script, see SO9).** `Sec-Fetch-User: ?1` is reliable only for a plain user-clicked
  submit: the Approve button is a link to a confirm page whose form posts without `data-confirm`; the revoke
  confirm page is the same. Reject keeps the native `confirm()`.
- **SO4 (fresh admin re-authentication for approve and revoke).** `GET /admin/login/start?mode=reauth&return_to=<path>`
  (an existing admin session only, else a normal login) sends `prompt=login` and `max_age=0`, binds `mode`, the
  allowlisted `return_to` (`/admin/oauth/(registrations|clients[/revoked])[/:id/(approve|revoke)]`, else
  `/admin/oauth/registrations`; since the SEC delta gate also the page `/admin/config`, exact string, for the two SSO trust forms and the OAuth switch, and since story admin-config-privileged-forms-sweep the pages `/admin/config/claim-mapping` and `/admin/config/role-mapping`, see SO10) and `started_at` into the signed login state. The callback runs the normal admin
  path, then accepts an `auth_time` from `started_at - 30 s` to `now + 30 s` as fresh (kind `auth_time`); an
  older or invalid `auth_time` is NOT fresh (the IdP skipped the login; an error flash). Fresh writes the session key
  `admin_reauth = %{"sub", "at", "kind", "path"}` (outside `current_user`, which the silent refresh rebuilds) and
  redirects to `return_to`; the POST is never replayed. Since review cycle 1 (Kassandra M-1) the marker is BOUND to
  the confirm page it was started for (`path` = that `return_to`, i.e. one client and one action) and CONSUMED by
  the successful approve / revoke (one fresh sign-in, one decision; a typo in the typed host keeps it). A POST
  without a marker of the same `sub`, the same `path`, at most 300 s old (5 s future skew) redirects to the
  re-authentication start. The silent refresh never writes it; logout drops the session with it. Batch approvals
  therefore need one sign-in per client.
- **SO5 (`auth_time` fail closed by default, explicit opt-out).** An IdP without `auth_time` cannot prove a new
  sign-in (the same rule as E-2 / gate y), so an ABSENT `auth_time` is not fresh unless
  `NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME=true` (read in `config/runtime.exs`, only the exact value; kind `flow`,
  a WARNING). The opt-out never rescues a present but stale or invalid `auth_time`. The dev `docker-compose.yml`
  sets it (Dex has no SSO session with its local connectors); the deploy templates do not. Revocation without a
  fresh login: CR10.
- **SO6 (no framing).** Every response under `/admin/oauth/` (the 403 page included) sends `frame-ancestors 'none'`,
  `X-Frame-Options: DENY` and `Cache-Control: no-store` (confirm pages carry a CSRF token, client data and the
  re-authentication state); the per-response logo widening of `img-src` still works; other admin pages keep
  `'self'`.
- **SO7 (honest residual risk).** Stopped: fetch / XHR posts (no `navigate`), hidden iframes, a scripted
  `form.submit()` WITHOUT any user activation (no `Sec-Fetch-User`), cross-site and same-site posts, stale admin
  sessions, a marker reused for another client or action (path-bound, single use). NOT stopped: a same-origin
  script that waits for ANY user click anywhere on the origin: a click gives the page transient activation, so
  `form.submit()` (to a popup, or a navigation) then sends `Sec-Fetch-User: ?1` and all four strict headers pass;
  the script reads the confirm page (CSRF token, host) with `fetch()`, and a fresh sign-in the admin completes at
  the IdP (the IdP prompt is visible) satisfies the marker for that ONE page. With the SO5 opt-out and an IdP that
  silently reuses an SSO session the re-authentication proves nothing; some IdPs (e.g. Microsoft Entra) ignore
  `max_age=0`, which shows as a stale-login loop and fails closed; browsers without fetch metadata at all (Safari
  before 16.4, a proxy that strips the headers) are locked out of the strict actions (accepted); Safari 16.4+ is NOT locked
  out, see SO9. An Element Web XSS already yields the user's
  access token: these checks protect the higher-trust actions only. Only a separate origin removes the class.
- **SO9 (Safari / WebKit: the click proof, story safari-fetch-metadata-compat, 2026-10-14).** Correction of an earlier
  claim: Safari does NOT send `Sec-Fetch-User` (it sends `Sec-Fetch-Site`, `-Mode`, `-Dest` from 16.4 on), so the strict
  level of SO2 locked every Safari user out of approve, reject, revoke, bulk removal, the `/admin/config` SSO trust saves
  and the `/account` reset approval (found on the dev stack). `Sec-Fetch-User` only tells the server that a user activation
  caused the navigation. Replacement for browsers that cannot send it: every strict form has a hidden field
  `_click_proof` (empty), which the ONE shared script (`Nebu.Web.ClickProofScript`; the admin loads the byte-identical copy
  from `app.js`, CSP `script-src 'self'`; the `/account` reset page embeds it and pins it by SHA-256, the only account page
  with a script, rendered only while the approve form is) sets to `1` on a TRUSTED click or Enter (`event.isTrusted`), and
  clears after 2 s and on `pageshow`. `BrowserPost.check_fetch_metadata/3` (and `check/3` with `params:`) accepts an ABSENT
  `Sec-Fetch-User` only when `Sec-Fetch-Site` / `-Mode` / `-Dest` are strictly correct, the field is `1` and the single
  `User-Agent` looks like WebKit (`AppleWebKit/` and none of `Chrome/`, `Chromium/`, `Firefox/`: Safari, and iOS browsers,
  which are WebKit). Chromium and Gecko always send `?1` on a user activation, so for them an absent header stays refused
  and a forged field is ignored (no downgrade); page script cannot set the `User-Agent` of a navigation. A present
  `Sec-Fetch-User` other than `?1` (also duplicated) is refused in every case; `fetch()` (mode / dest), iframes,
  cross-site / same-site posts stay refused. WebKit with correct headers but without the proof is a NOTICE, not an error:
  the admin gate answers `200` `data-page="oauth-activation-unproven"` (nothing changed, nothing audited, the
  re-authentication marker not consumed, a link back), `/account` redirects to the reset page with the notice
  `activation_unproven`. Residual (honest): the field is attested by page script, not by the browser, so a script running in
  the shared origin can set it, and on WebKit it no longer has to wait for a user click (SO7 widened for WebKit only);
  SO8 (own origin for Element Web) remains the fix. The lenient level (consent POST, legacy SSO confirmation, the other
  `/account` POSTs) never required `Sec-Fetch-User` and is unchanged: Safari works there.
- **SO10 (sweep of the other privileged admin forms, story admin-config-privileged-forms-sweep, follow-up `cw`).** One mechanism, no third: `OAuthAdminHelpers.gate/3`
  (strict fetch metadata incl. the SO9 click proof, `:marker` = additionally a fresh sign-in bound to the page, `:click` = no marker), the router's unframed
  rule (`frame-ancestors 'none'`, `X-Frame-Options: DENY`, `no-store`, decided on `path_info`) and the audit writer. Per form: **role mapping**
  (`admin_group_claim`, decides who is an administrator) `:marker` bound to `/admin/config/role-mapping`; **claim mapping** (`oidc_user_id_claim`,
  `oidc_displayname_claim`, `oidc_email_claim`, decides which IdP claim identifies a user) `:marker` bound to `/admin/config/claim-mapping`; both
  pages unframed (GET too), `reauth_return_to/1` accepts exactly those two pages besides the existing targets. **OIDC scopes** and **refresh mode**:
  `:click` (strict fetch metadata, NO marker): they grant no authority by themselves (on an instance without a configured admin claim path the any-key claim scan can be fed by an extra scope: the accepted scanner risk; they change the claim set the IdP issues and the token lifetime, hence they are audited, `oidc_scopes_changed` / `oidc_refresh_mode_changed`), and the marker's own sign-in uses the admin OIDC client WITH
  these scopes / refresh mode, so a wrong value would lock the admin out of the very sign-in needed to correct it. SSO origins, SSO schemes and the OAuth
  switch keep `:marker` (SO4 / AS4). Accepted consequence for the two marker forms: a wrong role mapping value locks all administrators out (the admin check is evaluated again at the
  next refresh and in the re-authentication callback, so an open session cannot undo it) and can be corrected with SQL only (07-deployment); a wrong claim
  mapping can be corrected on the page again (administrators stay administrators). The pages warn accordingly. The Role mapping page now says what the
  field is: the group VALUE under the configured claim path, refuses the values that occur in every token (`offline_access`, `default-roles-*`, protocol scopes, the configured issuer / client id: a too BROAD value makes every user an administrator, SEC delta
  gate X2-1) and the operator can recover without database access through `Nebu.Release.reset_admin_group_claim/1`, `reset_oidc_scopes/0` and `disable_oauth/0` (`bin/nebu rpc`, X2-6). Audit rows (since story admin-config-audit-atomic in the SAME transaction as the save, see the addendum below): `sso_redirect_schemes_changed` (Y-5), `oidc_claim_mapping_changed` (the three claim names) and
  `admin_group_claim_changed` (the group value);  The bootstrap wizard keeps its own
  controller and is not gated (no admin session and no IdP sign-in exist yet). Migration 000049 adds `admin_group_claim` to the `server_config` update
  allowlist (before it a save of the role mapping raised an RLS error on a bootstrapped instance). Not in this sweep (follow-up `de`): logs retention, media settings and
  the storage target, the user / room / space actions. SO7 stays the accepted residual.
- **SO10 addendum: self-lock-out guard of the role mapping (story role-mapping-self-lockout-guard, follow-up `dg`).** The Role mapping page refuses a group
  value that the SAVING admin would not satisfy. The claims come from the FRESH sign-in the marker already proves: the callback of `mode=reauth` writes, for the
  return page `/admin/config/role-mapping` only, `claims_fp` (the concatenated 6-byte prefixes of `SHA-256("nebu-role-fp:" <> value)` of the distinct
  string values that `Nebu.Web.OidcClaims.string_values_at/2` returns for the configured claim path: exactly the set the admin check `claim_at_path_matches?/3`
  can match; sorted, at most 32), `claims_fp_complete` and `claims_fp_path` (the path they were taken from; a marker made under another path is `:unknown`)
  into the marker. On an instance WITHOUT a stored claim path (the admin check scans every claim) the fingerprint leaves out the protocol and identity claims
  (`iss aud azp sub sid nonce typ acr amr auth_time email name preferred_username ...`): their values occur in nearly every token (Keycloak `typ` "ID", `acr`)
  or identify only the saver, and a role mapping value must never be taken from them (SEC review M-1 / L-1); the page says so. The session is a SIGNED,
  not encrypted, cookie of at most 4 KB that also carries the encrypted refresh token (a 2 KB base64 refresh token blob plus the marker with a full
  fingerprint measured 3.9 KB: the cap of 32 keeps the headroom, an IdP with refresh tokens of 3 KB or more would overflow the cookie on every reauth, with or
  without this guard), so it never holds a claim value, only these hashes (at most 192 bytes). A token exchange at save time was rejected (an IdP round trip and
  a refresh-token rotation inside a form post). After the gate, the empty refusal and the X2-1 universal-value refusal, `Auth.reauth_role_check/2` answers
  `:ok`, `:not_in_token` (complete fingerprint, value absent), `:undecidable` (the token has more than 32 distinct values at the path, the value is not in the kept
  part, sorted order) or `:unknown` (no well-formed fingerprint: a marker of a build without the guard during a rolling deploy, another path); everything but
  `:ok` answers 200, writes and audits nothing and keeps the marker, with its own message ("Not saved. ..."), a link to a new sign-in (`:not_in_token`,
  `:unknown`: the kept marker stays valid for 5 minutes, so the old fingerprint would otherwise be consulted again) and, for the two refusals the admin cannot
  fix at the IdP, the complete operator command. **There is no override ("I lock myself out on purpose")**, deliberately (Kassandra agrees): an admin who moves
  to a new group joins it at the IdP, signs in again and saves; an intentional hand-over to other people is done by them, or by the operator with
  `Nebu.Release.reset_admin_group_claim/1` (`bin/nebu rpc`, audited, deliberately not guarded); a checkbox is one more click-through to the very lock-out the
  guard prevents, and its recovery needs the operator anyway. Limits, honestly: the guard protects the saving admin only, other administrators lose access
  when their token lacks the value (that is the purpose of the change, the page says so); a value only the saver holds (a personal group, with a stored path)
  locks the co-admins out: accepted, audited, recoverable with the rpc; it checks the claims of the fresh sign-in, the next refresh uses the claims of the
  refresh-token exchange (same scopes; an IdP that omits the group claim from refresh tokens is a configuration problem); the 48-bit hash prefix is unkeyed, a
  second preimage (about 2^42 hashes) is feasible only for someone who can read their own cookie and who is the admin already; during a rolling deploy an old
  node skips the guard for a marker that carries a fingerprint; with more than 32 distinct values at the path the guard cannot decide for a value outside the
  kept part (the page refuses and names the rpc). The page shows the configured claim path read-only.
- **SO10 addendum: atomic audit of the config saves (story admin-config-audit-atomic, follow-ups `dh`, `di`, SEC delta gate X2-4 / X2-5).** The six privileged
  `server_config` forms (role mapping, claim mapping, SSO origin list, SSO scheme list, OIDC scopes, OIDC refresh mode) no longer audit AFTER the save: they call
  `Nebu.Admin.DB.save_config_audited/2` (through `OAuthAdminHelpers.save_config_audited/3`), which runs the upserts and the audit function in one transaction (the pattern
  of the OAuth switch, AS7): a change is never unaudited and an audit row never describes a change that did not happen; the caches of `upsert_server_config/1` are
  refreshed after the commit. The question "may a broken audit table block the save" is answered per form with the kill switch principle (AS7: a roll-back or reset
  must never hang on an unwritable audit table; an authority change must never be unaudited): **role mapping and claim mapping: refused** (authority / identity;
  the operator's way back without the UI is `Nebu.Release.reset_admin_group_claim/1` or SQL, and the rpc functions write the value first and the row second, so
  they never hang on the audit table); **SSO origin list and scheme list: refused for a widening, applied without the row for a subset** (a narrowing or clearing is
  the way back; the new list is a subset of the stored one when every token of it is a token of the stored one, case-insensitive, an unreadable stored value counts as
  empty); **OIDC scopes: refused unless every changed key narrows** (subset, case-sensitive tokens; a clear is the way out of a scope that breaks the IdP sign-in, extra
  scopes widen the claim set, X2-2); **OIDC refresh mode: applied without the row only when every changed key goes to `online` or stays as stored** (`offline` adds `offline_access`: a refresh
  token that outlives the user's IdP session, a widening, SEC review L-2; `online` is the way out of a sign-in lock-out). The stored value of a list counts as the runtime reads it (a stored value the validator would refuse as a whole is the empty set, SEC review L-1), and the retry
  without the audit function re-checks the narrowing inside its own transaction under a row lock (`SELECT ... FOR UPDATE`, SEC review L-3). A refused save changes nothing, keeps the marker and says "<form> not saved: the audit entry could not be written ..."; a save without its row consumes
  the marker, logs one value-free ERROR naming the form and the changed keys and says "... saved, but the audit entry could not be written ..."; a missing actor counts as a failed audit. A SIEM filter on
  `sso_redirect_origins_changed` must also watch `oauth_switch_changed` (the issuer origin is a legacy-SSO trust source, X2-4). The test seams of these forms (the
  per-form writers, `:admin_config_tx`, `:admin_server_config_reader`) are read only inside `if Mix.env() == :test` (follow-up `dd`, partly). X2-5 / `di`:
  `Nebu.Matrix.SsoStore.peek_confirm/1` reads the named, protected ETS table directly, no call to the node-local store process, so the confirmation page's lookup is
  not queued behind `put_state`, the loginToken mint and the `/login` redemption (a flood of well-formed random cookies can no longer delay them through this
  call; `put_confirm` / `pop_confirm` and the replication stay in the process; the stateless MAC cookie variant stays a follow-up).
- **SO11 (the remaining admin forms, story admin-forms-gate-sweep, follow-up `de`).** The mechanism stays `OAuthAdminHelpers.gate/3` (no new one); levels: (a) strict
  fetch metadata + a fresh sign-in marker bound to the page, (b) strict fetch metadata only (`:click`, the controller plug `click_gate/2`), (c) unchanged. **(a)**: the media
  policy (`POST /admin/media/settings`: `released_delete_after_days` / `deleted_days` / `infected_days` of 0 destroy all released attachments and the infected evidence, `webhook_url`
  blinds the alerts) and the media storage target (`POST /admin/media/settings/storage`: every future upload goes to an attacker's store and that store's content is served back; the
  stored credentials are encrypted, the endpoint is not a secret), both bound to `/admin/media/settings`: **one marker per page**, because the page holds ONE object (the instance
  configuration; the per-object bindings of the OAuth approve / revoke exist because a marker earned for one client must not be spent on another); consumed after a successful save, kept after a
  validation error; the page is unframed; break-glass while the IdP is down is SQL on `media_storage_config` (the row wins over the environment). **(b)** and a logic fix: the test connection
  (`.../storage/test-connection`) persists nothing and needs no marker (the marker is never touched), but the stored credentials sign a request to the SUBMITTED endpoint (the access key id and a
  signature that allows offline guessing of the secret): `StorageConfig.test_connection/1` reuses the stored access / secret key only when the candidate endpoint and scheme equal the stored ones,
  else `{:error, :secret_required}` (the IAM / STS endpoints are not compared: the test never contacts them). **(b)** for every other form post and DELETE except the bootstrap wizard (one testable
  rule: a router enumeration test fails for a new unlisted route): device rename and delete, create room / space, room settings (visibility), archive / unarchive, force-join and force-leave
  of members (a marker would need per-room bindings and an IdP sign-in for routine onboarding), auto-join toggles (a flip, reversible), space name / children, the log retention save. NO marker
  on the incident-response actions (delete device, force-leave) and on log levels: they must work while the IdP is down. Audit: the log retention save writes value and `log_settings_changed` row in
  one transaction (`save_config_audited/3`; refused when the row cannot be written except a pure "collection off" change), the three media retention values (`released_delete_after_days`, `deleted_days`, `infected_days`) write their `media_config_updated` row in one transaction with the value (story media-retention-audit-atomic, follow-up `dn` partly closed, owner decision 2026-10-15: a shortening is refused when the row cannot be written, a lengthening or disabling is saved without it after one value-free ERROR; the other media keys stay best effort), the room auto-join toggle uses the audited `Nebu.Matrix.set_room_auto_join/3`
  (it was raw SQL without a row; the row is best effort, after the write, like the space toggle: follow-up `dn`). **(c)** with the residual stated: the bootstrap wizard (before any admin exists; whoever completes it first configures the IdP; step 2 makes an unguarded
  server-side GET to the entered issuer, pre-existing), `GET /admin/logout` (a cross-site logout is a nuisance, `SameSite=Lax`; a same-origin script can log the admin out anyway), and the LiveView websocket
  events (media block / unblock / delete / rescan / override, War Room, Trace Map): the websocket carries no fetch metadata, so a script on the shared origin (SO7) can do over LiveView everything an
  admin can (block, unblock or soft-delete media with no restore in the UI, start a War Room capture, override infected media only with the `media_admin_override` grant and a reason); limits: the media
  audit rows, one active War Room, the `deleted_days` window in which SQL can still restore. **Audit decisions (owner, 2026-10-15, story space-edit-audit, follow-up `dj`):** the Admin UI edits of a Space ARE
  audited: `space_name_changed`, `space_topic_changed`, `space_child_added`, `space_child_removed` (target_type `room`, target = the space, metadata name / topic cut to 256 characters or `child_room_id`, plus the `event_id` of the
  state event), written by `Nebu.Matrix.set_space_state/5` after a successful write (the admin entry point; `Dispatcher.set_room_state/2` stays unchanged because it also serves Matrix clients, whose edits are not admin actions).
  Not atomic with the event (Room GenServer path, like the audits of the auto-join toggle, visibility change and member add): a failed audit write is logged and does not undo the edit; the `events` row with sender = the
  administrator stays the primary record. Decided: no audit for `configure_logging` of the Trace Map (`dk`), War Room / diagnosis start and stop (`dl`), bootstrap completion and admin login / logout (`dm`). Not decided here
  (owner / compliance, follow-ups `dj` - `do`): the atomic audit of the other media policy keys, the discarded pinned SSRF target of the storage test (closed by story storage-test-pinned-target, see the SO11 addendum below), the stored-secret rule on the storage save path; `ab` stays open.
- **SO11 addendum: the pinned storage test target (story storage-test-pinned-target, follow-up `do` part a, SEC delta gate forms-sweep X3-2, owner decision 2026-10-15).** `StorageConfig.validate_candidate_endpoint/1`
  used to keep only the `:ok` of `Nebu.Media.SSRF.checked_target/2` and throw the checked target (`%{scheme, host, ip}`) away; the test connection's `ExAws` request then resolved the host AGAIN, so a DNS server could
  answer a public address to the check and a private one to the request (DNS rebinding, time-of-check / time-of-use). **Decision:** the checked target is returned and carried to the request
  (`test_connection/1` puts it into the candidate as `:pinned_target`), and the request is made by a small `ExAws.Request.HttpClient`, `Nebu.Media.PinnedHttpClient`, selected per request through the ExAws config override
  (`http_client:` / `http_opts: [pinned_target: target]` of `config_overrides/1`; the operational calls keep the default client). It connects to the **checked IP** (the first resolved address; all answers were checked, the
  existing `allow_private` opt-in `NEBU_STORAGE_ALLOW_PRIVATE_ENDPOINTS` is unchanged), and keeps the original name where it matters: the `Host` header (AWS SigV4 is computed over the original `host[:port]`, so MinIO / S3 accept it), for https the
  TLS SNI and the certificate hostname verification (hackney verifies against the SNI, a certificate for the IP only is refused and the request is not sent; `ssl_options` of `config :ex_aws, :hackney_opts` are merged, the pin only sets the SNI).
  It fails closed (no pinned target, or a URL host that is not the pinned host, is an error, never a normal resolution), does not follow redirects (a `Location` would bypass the pin), uses no connection pool and no proxy option
  of its own, handles IPv6 in brackets and the default ports. `upsert/1` (save) performs no request, it validates only, so there is no second resolution to pin there (the checked target is not kept). **Residual, recorded as a new follow-up
  (not fixed here):** the operational S3 calls (`Nebu.Media.Storage`, `ExAws.request()` with the stored endpoint) resolve the stored host name per request, so a rebinding AFTER a successful save / test remains a residual of the admin-trusted
  endpoint (admin only, fresh sign-in, strict gate). **Part b of `do`** (the stored-secret rule of the test connection is not applied on the save path) is NOT implemented: split out as an own feature (owner idea), not part of this epic.
  **Consequences of the pin:** the client speaks HTTP/1.1 only (HTTP/2 would put the pinned IP into `:authority` and drop the `Host` header the signature covers), the test connection pins the FIRST resolved address (a multi-record host with a dead first node fails deterministically) and makes ONE attempt (no ExAws retries); behind an environment proxy the proxy sees the IP (https: `CONNECT ip:port`, SNI and certificate check by name) and `NO_PROXY` is matched against the IP, not the host name. An endpoint with user info (`user@host`) is refused. A 302 / 303 / 307 / 308 answer is an error (`redirect_not_followed`), never followed. **Test seam:** `Application.put_env(:nebu_http, :media_ssrf_resolver, fun)` (`fun.(host) -> {:ok, [ip]} | {:error, atom}`, host names only, read at call time) replaces the system resolver in `checked_target/2`, so a test can simulate rebinding;
  it also serves `preview_url` and the webhooks. **Defect found and fixed with it:** hackney 4.x answers a `HEAD` with `{:ok, status, headers}`, which `ExAws.Request.Hackney` does not match, so the production test connection raised a
  `CaseClauseError` against any server; the pin client maps it (a 403 / 404 / 5xx now arrives as `{:error, {:http_error, status, _}}`).
- **SO8 (deployment recommendation).** Serve Element Web on its own hostname; the Nebu host keeps `/_matrix`,
  `/.well-known`, `/oauth2`, `/account`, `/admin` (an example `server` block is in 07-deployment, "Reverse
  proxy"). A dedicated admin hostname is not possible yet (follow-up ba).

### Manual verification (operator, before `oauth_enabled`)

Fail closed until verified (the defaults refuse): (1) Dex: does the admin id_token carry `auth_time`, are `max_age=0` /
`prompt=login` honoured (else the opt-out or the rpc is needed); (2) Chrome and Firefox send the four fetch
metadata headers, Safari the three it implements plus the click proof `_click_proof` (SO9), on a click AND an Enter-key
submit of the approve / revoke confirm pages, reject, bulk removal, the `/admin/config` SSO trust forms and the reset
approval, through the reference nginx (MANUAL, per browser; Safari with the script blocked shows the notice page); (3) Element X / FluffyChat open `/account` in a system browser tab that sends fetch
metadata; (4) a `fetch()` POST and a hidden-iframe form submit to the revoke URL are refused; (5) revoking a client with
a live Element Web session logs Element Web out at its next request and removes the device; (6) `bin/nebu rpc` works in
the reference containers for both CR10 functions.

## Room summary and `M_UNRECOGNIZED` (phase 2, story oauth-room-summary-unrecognized)

Closes follow-up gates (ac) (`GET /_matrix/client/v1/room_summary/{roomIdOrAlias}`, CORE in Matrix v1.15) and
(af) (spec `M_UNRECOGNIZED` for unrouted endpoints and unsupported methods). `oauth_enabled` is untouched
(only the live-only 405 of RU14 reads the OAuth state); no migration. Oracle gate 2026-10-12: PASS.

- **RU1 Local only.** No federation, no outbound HTTP, `via` and other query parameters ignored. An alias
  resolves only through `Nebu.Matrix.Room.DB.lookup_alias/1` (unknown => 404, any server part).
- **RU2 Auth required** (Protected, OidcPlug; legacy and OAuth tokens alike). The spec MAY (unauthenticated) is not taken.
- **RU3 Existence before state; one 404 for everything hidden.** `get_room_status/1 == {:ok, "active"}`
  first, only then the state read (it lazy-starts a Room and inserts a `rooms` row for an unknown id, so an
  unchecked read would create a row and a process per chosen id). Unknown, archived and not-visible rooms
  answer the byte-identical `404 M_NOT_FOUND "Room not found"` (anti-enumeration; unlike `/hierarchy`'s 403).
  Accepted risk (Kassandra L-1): the room state is read (and the Room lazy-started) BEFORE the visibility decision, so
  a hidden room answers a little slower than an unknown id (existence is observable by timing only; the bodies are
  byte-identical). Follow-up bg: decide visibility from the DB first.
- **RU4 Visibility (review cycle 1, Kassandra M-1):** a ban ends a pending invitation (`ban_user/2` rejects it, which also
  removes the stale invite from /sync, which reads the same table) and the latest `m.room.member` `ban` is checked before the
  invite, so a banned former invitee sees a room only by rule (membership `ban`). Kick cannot revoke an invite (follow-up bl). Visible: joined, pending invite, `join_rule` `public` / `knock` / `knock_restricted`, or
  `world_readable`. `restricted` rooms are not visible through `allow` (as `/hierarchy`; follow-up bi).
- **RU5 Shape:** spec `RoomSummary` + `membership` (a never-member sees `leave`: a Nebu choice, the spec defines
  no default). Optional keys are absent, never `null` / `""`; `topic` from the `m.topic` text/plain block, else
  the legacy topic; `allowed_room_ids` only for restricted rules; pure builder `Nebu.Matrix.RoomSummary.build/3`.
- **RU6 No unstable alias** `im.nheko.summary`: matrix-js-sdk falls back and fails as today (follow-up bh).
- **RU7 Rate limit** (recorded deviation from "Rate-limited: No"): tier `room_summary`, 300/min, burst 60, per user.
- **RU8 Validation:** the path param as Plug decoded it (no second www-form decoding), `!` or `#`, at most
  255 bytes, `:` required only for aliases (v12 room ids may lack a domain); invalid => 400 `M_INVALID_PARAM`.
- **RU9 Scope:** the fall-throughs of Protected, `Router.Media`, `Router.ClientV1Media`, `HttpPublic`, the
  non-GET methods of `/_matrix/client/versions`, RU14. Non-Matrix paths, `/admin`, `/oauth2/*`, `/account*`,
  `/.well-known/*` keep their own answers.
- **RU10 Unknown endpoints have no auth requirement.** Pipeline `:fetch_query_params` -> `:match` ->
  `:authenticate` -> `:dispatch`; the catch-all is `match _, private: %{nebu_unrecognized: true}`, the public
  `authenticate/2` skips the OidcPlug ONLY for that boolean marker, so every real route stays authenticated
  (fail closed, guarded by a test per route clause). Accepted disclosure: an unauthenticated caller can tell
  implemented (401) from unknown (404) paths; the route set is public anyway.
- **RU10a `POST /_matrix/client/v3/register`:** routed explicitly in the top router, no auth, `403 M_FORBIDDEN
  "Registration is not enabled on this homeserver."` for any body / kind / token; other methods 405; sub-paths 404.
- **RU11 405, HEAD, OPTIONS.** The catch-all probes the router's own `do_match/4` clauses (marker removed) with
  the other methods: a real match => `405` + `Allow: <methods>, OPTIONS`, none => 404. HEAD is not mapped to
  GET (a recorded deviation from the RFC 9110 SHOULD). A non-preflight OPTIONS => 204 + `Allow` on a known path
  (no auth, no logic), 404 on an unknown one.
- **RU11a Carve-out (pre-dev review M1):** `GET /rooms/{id}/state` and `/state/{type}[/{key}]` are not
  implemented (only PUT exists) but clients read `404 M_NOT_FOUND` as "state absent": exactly these GETs keep
  today's `404 M_NOT_FOUND "Unrecognized request"` until follow-up bf implements them; other methods follow RU11.
- **RU12 Handler-level errors stay** (`M_NOT_FOUND` of account data, devices, media, profile, `room_keys`,
  `voip`, ...; a handler's own 405 such as `M_BAD_JSON`): only requests that reach `match _` change.
- **RU13 HttpPublic root by `conn.script_name`:** `login` GET/POST, `refresh` POST, legacy `auth_issuer` /
  `auth_metadata` GET, `auth` / `profile` none; other methods 405 / 404. A POST on `/v3/auth`, `/v3/profile`
  or a legacy discovery path no longer runs `do_login` (a pre-existing bug, measured by the ATDD).
- **RU14 OAuth discovery while live:** a non-GET on `auth_metadata` / `auth_issuer` => `405 M_UNRECOGNIZED` +
  `Allow: GET, OPTIONS` iff `Config.live_state/0` is `{:live, _}`, else the unchanged 404.
- **RU15 Bodies:** 404 `{"errcode":"M_UNRECOGNIZED","error":"Unrecognized request"}`, 405 `... "Unsupported
  method"`, JSON content type, today's CORS headers; the fall-through writes no log line.
- **RU16** `/_matrix/client/v3/versions` stays unrouted (ae): 404 instead of 401.
- **RU17** No Gherkin (`ui: false`): ExUnit plus manual verification.
- **RU18 Side finding, not fixed:** reads that lazy-start a Room insert a `rooms` row for any unknown id
  (`/hierarchy`, `GET /rooms/{id}/members`, ...; follow-up bg).

Gate status: (ac) closed, (af) closed (with RU10a and the RU11a carve-out).

## Client-hosted logos (decision Phil, 2026-10-09)

`logo_uri` is attacker-chosen. Rendering it as `<img>` makes the ADMIN's browser contact the
registrant's host merely by opening the approval page: the admin's IP/User-Agent leaks and the
registrant gets a blind GET probe from inside the admin's network. Hence:

- By default the approval page renders no `<img>` and contacts no client-hosted URL. The Content
  Security Policy stays the strict admin policy (`img-src 'self' data:`). The logo URL is shown as
  text (host prominent) so the admin can still judge it.
- A "Load logos" control (`GET /admin/oauth/registrations?logos=1`, per page, not sticky) renders
  the images (https only, `referrerpolicy="no-referrer"`, `loading="lazy"`). Only THAT response
  widens `img-src`, and only to the exact origins (`https://host[:port]`) of the logos shown on
  that page, never `https:`. The origins are validated strictly before they enter the header
  (https, no userinfo, ASCII DNS name with at least two labels and a non-numeric last label, so
  never an IP literal, also not in hex notation: security review F-4, N-2); a logo whose origin fails validation is neither
  rendered nor allowed. CSP also applies to redirects, so a logo host cannot bounce the browser to another
  origin.
- Trade-off: an extra click for operators who want logos, in exchange for no passive contact with
  registrant infrastructure. A server-side logo proxy/cache was considered and rejected for this
  story (it needs SSRF protection, size/type limits and storage: a separate decision). Deciding
  without loading logos is fully supported; logos are informational.

## Approval page (security review F-5, F-6)

- The page shows the `application_type`, labels name, client URI and logo as UNVERIFIED claims,
  and marks every redirect URI "host-bound" (https on the client_uri host or a subdomain) or "NOT
  host-bound: client identity unverified" (loopback, private-use scheme). A native client can claim
  any name, so those rows are flagged. The confirm dialog leads with the verified host:
  `Approve client at <host> (name "<name>")?`. Redirect hosts that differ from the client host are
  highlighted.
- Host validation (F-4): a `client_uri` / `logo_uri` / redirect host needs at least two DNS labels
  and a last label that is not a number in the WHATWG sense (all digits, or `0x` plus hex digits):
  no `https://com`, no IPv4 literal such as `10.0.0.5`, `0.1`, `127.0.0.0x1` or `0x7f.0x1`
  (security review F-4, N-2). Story oauth-dcr-abuse-hardening (AH4, AH5, AH7): a `client_uri` host that
  IS a public suffix (`github.io`, `co.uk`) is refused at registration, and a host below a multi-tenant
  hosting suffix (`name.github.io`) is shown with a "shared hosting domain" warning badge (a legacy
  pending row whose host is a public suffix gets an error badge); the registrable domain is shown
  when it differs from the host, and each row links to the bulk-removal preview of its domain.
- **Update (story oauth-client-revocation, SO2-SO4):** the list's Approve is a LINK to a confirm page
  (`GET /admin/oauth/registrations/:client_id/approve`: verified host first, redirect URIs with their
  host-bound badges, the shared-hosting warning and the re-authentication state) whose plain form posts
  without a JavaScript `confirm()`; the POST needs strict fetch metadata and a fresh admin
  re-authentication (marker `admin_reauth`, 300 s). Reject keeps the native `confirm()` and lenient fetch
  metadata. The audit row records `reauth`. See "Client revocation and same-origin hardening (story
  oauth-client-revocation)".
- Decision and audit row are written in ONE database transaction. A failed audit write rolls the
  decision back (the registration stays pending and the admin sees an error), so a decision is
  never unaudited. The rejection reason is stripped of control, format, private-use, surrogate and
  line/paragraph separator characters first (a NUL would make the jsonb audit insert fail). This
  deliberately differs from `AuditWriter`'s default of an independent audit transaction: here the
  audit row is part of the decision.

## Hardening and hygiene (story oauth-hardening-hygiene)

Phase-2 story P8 bundles the NON-GATING follow-ups (j, ah, p, story-3 (b), am, an, I-10..I-13 and the epic SEC
Gate 2 items E-5/E-6) that are worth doing before activation. `oauth_enabled` stays off by default. Decisions
`HY1`-`HY17` (prefix `HY`, no collision with D/T/R/C/A/V/TP/AH/FR/CR/SO/LL/RU). Migration 000047.

- **HY1 (per-node TTL cache of the switch state).** `Nebu.OAuth.Config.get/1` (so `live_state/1`, `enabled?/0`,
  `Nebu.OAuth.oauth_aware?/1`, `Nebu.OAuth.config/0`) serves the normalized `%{enabled, issuer_url, state}` from a
  per-node ETS entry `{:config, map, loaded_at_ms}` (table `:nebu_oauth_config_cache`) while `now - loaded_at < ttl`.
  TTL = `:nebu_http, :oauth_config_cache_ms`, set from `NEBU_OAUTH_CONFIG_CACHE_MS` in `config/runtime.exs` (integer
  `0..5000`; absent, junk or out of range => 2000; `0` disables the cache; `config/test.exs` pins `0` and
  `runtime.exs` never overrides it in `:test`). ONLY a successful read (`:enabled` / `:disabled`) is cached;
  `:unknown` (read error, timeout, exception) and `:no_repo` NEVER are, so every request during an outage re-reads and
  fails closed exactly as before. The `:oauth_config_source` seam bypasses the cache. `pending_limits/0` and
  `token_settings/0` stay uncached (rate-limited / authenticated callers; values apply on the next registration /
  refresh). Table absent => read-through, no exception, no table created by the caller.
- **HY2 (kill-switch semantics, ADR-020: bounded staleness).** Node-local state is accepted here as BOUNDED
  staleness, the same class as `Nebu.Web.OidcConfig` (ETS) and the 60 s JWT denylist cache: an operator write of
  `oauth_enabled` / `oauth_issuer_url` takes effect on every node within the TTL (default 2 s, at most 5 s), never
  later; no correctness property (single-use codes, rotation, revocation) depends on the cached value, those stay
  atomic SQL. "Next request on every node" in the docs became "within `NEBU_OAUTH_CONFIG_CACHE_MS` (default 2 s)".
  `/versions` keeps its bounded 500 ms read on a miss (a success fills the cache, a failure is `:unknown` =>
  v1.1-v1.11, never a 5xx); an enabled value younger than the TTL is served while the database is down
  (documented staleness), once expired `:unknown` answers.
- **HY3 (discovery rate limits only where the spec allows a 429).** Matrix v1.18 marks `GET /_matrix/client/v3/login`
  "Rate-limited: Yes" and `auth_metadata` "Rate-limited: No". Per-source buckets (`ClientIP.bucket/1`, own
  `RateLimit.take/3` keys, never the plug's bare-IP key shared by `POST /login` and `/refresh`): `{"login_flows",
  bucket}` 300/min, burst 300 (Matrix `429 M_LIMIT_EXCEEDED` + `retry_after_ms` + `Retry-After`) and
  `{"oauth_openid_configuration", bucket}` 600/min, burst 600 on the LIVE branch of
  `GET /.well-known/openid-configuration` (the JWKS 429 shape; matrix-js-sdk fetches it before every refresh; the
  disabled branch and a CORS preflight take no token). NO 429 on `auth_metadata`, `auth_issuer`, the unstable
  aliases or `/versions` (spec, load-balancer health check): they rely on the HY1 cache (no DB read on a hit).
- **HY4 (one supervised owner for the OAuth ETS caches).** `Nebu.OAuth.CacheOwner` (GenServer, child of
  `Nebu.Supervisor` after the Repo and before Bandit) creates `:nebu_oauth_config_cache` and
  `:nebu_oauth_signing_key_cache` in `init/1`. Request processes never create tables (before, the first request
  process owned the signing-key table and it died with it). Table absent => miss, never a crash; an owner restart
  starts with empty tables.
- **HY5 (compile-guarded config seams, an).** `:oauth_config_source`, `:oauth_config_repo` and
  `:oauth_config_cache_clock_fn` are read through a private `seam/2` that exists only under `if Mix.env() == :test`
  (idiom of `Nebu.Matrix.OAuthSession`); other envs get the default, so a stray `Application.put_env` in a release can
  never switch OAuth on (epic review I-6).
- **HY6 (I-10).** `confirm_text/3` renders the client name as a JSON string (`Jason.encode!/1`: escaped `"`, `\`,
  control characters) after a cut to 80 graphemes (`…`); the verified host comes first; invalid UTF-8 is replaced first
  so the function never raises.
- **HY7 (I-11).** Badge `host matches client_uri` / `NOT tied to the client_uri host: client identity unverified`;
  the `data-role` attributes and `redirect_binding/1` are unchanged.
- **HY8 (I-13).** `Nebu.Matrix.idp_complete_login/4` also catches `:exit` (logs `unexpected exit`, never the reason;
  `{:error, :idp_unavailable}`).
- **HY9 (`__Host-` binding cookies, j / ah).** On an https request (`Nebu.Web.RequestScheme.https?/1`) the per-flow
  binding cookies are `__Host-nebu_oa_<16 hex>` (authorize) and `__Host-nebu_acct_<16 hex>` (account login) with
  `Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=600`; on plain http today's names and attributes. The callback
  reads ONLY the name of its own scheme (no fallback to the legacy name: it would re-open sibling-subdomain cookie
  tossing); clearing uses the same name / path / secure; a scheme mismatch between authorize and callback (or a flow
  in flight across the deploy) is `400 invalid_state`. Accepted widening (Kassandra L-2): `Path=/` (a `__Host-` requirement) sends the 43-character binding value with every request to the host for at most 10 minutes (Max-Age 600); it is one-time per flow, HttpOnly, and useless without the matching state.
- **HY10 (DEFERRED: rotated-row cap, o).** Deleting consumed refresh rows beyond the newest N per device bounds row
  growth but shortens the T11 reuse-detection window (an old stolen refresh token would answer `invalid_grant`
  instead of revoking the session): security-negative, not done (follow-up bs).
- **HY11 (pre-published `next` key, migration 000047).** `oauth_signing_keys.status` admits `next`; at most ONE
  (partial UNIQUE index `oauth_signing_keys_one_next`); the INSERT policy admits `active` and `next`; the guard trigger
  keeps every 000042 rule and adds: `retired -> next` and `active -> next` forbidden, `next -> active` ONLY when
  `OLD.created_at <= now() - interval '900 seconds'` (JWKS max-age 600 s + id_token lifetime 300 s: every cached
  JWKS already contains the key), `next -> retired` needs `retired_at`. The 900 s rule is enforced by the database
  (it does not bind a compromised runtime role, which can also write the tables; accepted, follow-up bq).
  `published_keys/0` lists active, then next, then retired keys with `not_after > now()`.
- **HY12 (`Nebu.Release.rotate_oauth_signing_key/0`, two calls).** Call 1 (no `next` row, an active key exists):
  generate ES256, insert as `next`: `{:ok, {:published, kid, activate_after_iso8601}}`. Call 2 (a `next` row older
  than 900 s that LOADS: decrypt, thumbprint, public-part check): in ONE transaction retire the active key
  (`not_after = now() + 900 s`) and promote `next`: `{:ok, {:activated, new_kid, retired_kid}}`. Too early:
  `{:error, {:too_early, seconds_left}}`, no change; an unloadable `next` row: `{:error, :next_key_unavailable}`
  (use HY13); a lost race: `{:error, :conflict}`. Every call takes a transaction-scoped advisory lock
  (`pg_advisory_xact_lock`) after a snapshot of the `next` row and compares the row after it: a call whose picture
  changed while it waited (another operator published, promoted or discarded the key) answers `:conflict` and changes
  nothing, so a late caller never publishes a second `next` key on top of a rotation that just completed. Each successful call writes ONE audit row inside the transaction (`oauth_signing_key_published`
  / `oauth_signing_key_rotated`, actor `operator:rpc`, target type `oauth_signing_key`, target id = the new kid,
  metadata = kids only); a failed audit write rolls the step back. Run through `bin/nebu rpc`.
- **HY13 (emergency replacement of an undecryptable active key).** `Nebu.Release.replace_oauth_signing_key(:emergency)`:
  in ONE transaction retire the active key (`not_after = now() + 900 s`: its PUBLIC key still verifies id_tokens it
  signed) and any `next` row and insert a freshly generated `active` key (a `next` row is never promoted: it may be
  undecryptable under the same secret change). Audit `oauth_signing_key_replaced`. Consequence: clients holding a
  cached JWKS (up to 600 s) cannot verify new id_tokens until they refetch; no session is revoked. Any other
  argument (or none): `{:error, :confirmation_required}`.
- **HY14 (no key material anywhere).** The rotation functions return and log kids and atoms only, never the JWK, the
  ciphertext or an exception carrying parameters.
- **HY15 (operator note, ah).** A TLS-terminating proxy that does not set `X-Forwarded-Proto: https` makes Nebu issue
  the non-`Secure`, non-`__Host-` cookies (consent, account session, both binding cookies); 07-deployment says so.
  Gating the header on the trusted set stays deferred (ap2).
- **HY16 (e2e under the cache).** The e2e fixtures that write `oauth_enabled` / `oauth_issuer_url` wait until the
  running server reflects the write (poll `GET /_matrix/client/v1/auth_metadata`: 200 with the stored issuer when
  enabled, 404 otherwise; 100 ms interval, 5 s timeout, then fail loudly). The stack keeps the production default.
- **HY17 (SecretBox v2 design, DEFERRED, al / E-5).** Blob `"v2:" <> key_id <> ":" <> hex(nonce || ct || tag)`,
  `key_id` = 8 hex of SHA-256("nebu-kid" || secret); per-purpose key = HKDF-SHA256(secret, salt "nebu-secretbox-v2",
  info = purpose: `idp_refresh_token`, `pkce_verifier`, `signing_key`, `admin_client_secret`, `scim_token`,
  `storage_secret`); AAD = purpose || stable row identity (`user_id || device_id` for IdP refresh tokens, `kid` for
  signing keys; never the token hash, the ciphertext is copied across rotated rows). Decrypt: `v2:` => v2 (an unknown
  key_id => `NEBU_INTERNAL_SECRET_PREVIOUS[_FILE]`), else v1. Two releases: N reads v1+v2 and writes v1, N+1 writes
  v2 (rollback-safe); lazy re-encryption plus `Nebu.Release.reencrypt_secrets/0`; signing keys re-keyed via HY12.
  Deferred together with (t) (IdP-side refresh-token revocation) and (aq) (keyed `SourceKey` hash).

### Rotation procedure (operator)

1. `bin/nebu rpc 'IO.inspect(Nebu.Release.rotate_oauth_signing_key())'` publishes the next key (`{:ok, {:published,
   kid, activate_after}}`); the JWKS now lists the active and the next key.
2. Wait at least 15 minutes (`activate_after`), then run the same command again: `{:ok, {:activated, new_kid,
   retired_kid}}`. The old key stays in the JWKS for 15 more minutes, so id_tokens signed before the switch still verify.
3. `NEBU_INTERNAL_SECRET` changed and the active key no longer decrypts: `replace_oauth_signing_key(:emergency)` (HY13);
   rotating the secret also logs out `per_refresh` OAuth sessions (their IdP refresh tokens no longer decrypt, (al)).

### Manual verification (operator, before `oauth_enabled`)

| Check | How | Expected |
|---|---|---|
| Cache TTL in the real cluster | Two nodes; flip `oauth_enabled` by SQL; poll `/versions` on each node | Both flip within 2 s (default) |
| Cookie attributes behind the real proxy | Browser devtools on an authorize and an account login over https | `__Host-nebu_oa_...` / `__Host-nebu_acct_...`, `Secure`, `Path=/`; if not `__Host-`, the proxy does not send `X-Forwarded-Proto: https` (HY15) |
| Rotation with real clients | Run HY12 call 1, wait 15 min, call 2 while Element Web / FluffyChat sessions refresh | No logout and no id_token validation error at login / refresh |
| Emergency replacement | Staging only: run HY13 | Logins work again; a client with a cached JWKS may reject new id_tokens for up to 10 min (record which clients refetch on an unknown `kid`) |

## Phase 2 summary (gate closing) and activation readiness

Phase 2 of epic `oauth-broker` (2026-10-12/13) closed the activation gates of the "Gate items" section. `oauth_enabled` is still
`false` by default and nothing in the repository enables it; activation is an operator decision after the manual verification.

**Stories.** `oauth-trusted-proxy-client-ip` (P1, gate 1), `oauth-dcr-abuse-hardening` (P2: 2, 3, 4, h, aa), `oauth-authorize-freshness` (P3: i, y, l, n,
ak(1)-(3), E-2), `oauth-client-revocation` (P4: aj, ag incl. E-3, ax), P5 deploy templates (m, k, ae, ap1; templates and docs only), bugfix
`legacy-logout-per-device` (r, x), `oauth-room-summary-unrecognized` (ac, af), `oauth-hardening-hygiene` (P8: j, ah, p, story-3 (b), am, an).
Migrations 000044 (abuse caps), 000045 (consent requests, refresh leases, nullable `auth_time`), 000046 (`revoked` clients), 000047 (`next` signing key).

**What changed architecturally.**
- *Client IP:* one resolution plug (`Nebu.Web.Plugs.ClientIP`) honours `X-Forwarded-For` only from `NEBU_TRUSTED_PROXY_CIDRS`; every per-IP consumer reads
  `Nebu.Web.ClientIP.get/1` (exact address) or `bucket/1` (IPv4 per address, IPv6 per /64); per-source caps use `Nebu.OAuth.SourceKey` (hashed, /64);
  idle buckets are swept per node.
- *Consent and freshness:* every authorization passes a consent step (`Consent`, `ConsentStore`, a hash-pinned arming script against double clickjacking,
  `BrowserPost` strict fetch metadata); freshness is server-owned and fail closed (an absent `auth_time` is never fresh); a per-device IdP refresh
  lease (`oauth_idp_refresh_leases`) serializes the IdP leg of a refresh.
- *Client revocation:* status `revoked` (final for the registration); one transaction ends sessions, devices, codes, requests and consents with the locked
  teardown plus an audit row (`Nebu.OAuth.revoke_client/3`, `Nebu.Release.revoke_oauth_client/2`, `revoke_all_oauth_sessions/0`); `/admin` approve / revoke
  need a fresh admin re-authentication bound to one client and action (SO1-SO6).
- *Legacy logout:* `Nebu.Matrix.legacy_logout_device/1` ends only the presented credential's device; legacy `/refresh` takes the devices lock.
- *Unrecognized routes:* `Nebu.Web.Unrecognized` answers `M_UNRECOGNIZED` (404 / 405) for Matrix fall-throughs without authentication; room_summary is local only.
- *Config cache:* `Nebu.OAuth.Config` caches the switch state per node in ETS (`Nebu.OAuth.CacheOwner`, `NEBU_OAUTH_CONFIG_CACHE_MS`, default 2 s): a conscious exception
  to ADR-020's "no node-local state" as bounded staleness (HY2); correctness-relevant state (single-use codes, rotation, revocation) stays atomic SQL.
- *Signing keys:* `next` status and a database-enforced 900 s promotion rule, two-call rotation and an emergency replacement (`Nebu.Release`, HY11-HY13).

**Accepted risks.** SO7: Element Web, `/account` and `/admin` share one origin (the strict checks stop fetch / XHR, framing and stale admin sessions, not a script waiting
for a user click); legacy `m.login.sso` (legacy bypass) accepts ANY https `redirectUrl`: `GET /_matrix/client/v3/login/sso/redirect?redirectUrl=https://evil/` leads through IdP login (which only the IdP's `prompt=login` handling protects) to a 302 to the attacker host with a `loginToken` that `POST /login` exchanges for a full session; no approved client, device id or consent is involved, it is independent of `oauth_enabled`, and the epic's E-2 closure holds for the OAuth path only (G3-3: CLOSED in the server afterwards by story legacy-sso-redirect-confirmation, the Synapse-style confirmation page plus allowlist, follow-up `by`; residuals in "Legacy SSO redirect confirmation" L8; manual verification group F); the consent double-click arming was beatable by a multi-gesture lure (G3-5, REDUCED in the server by story consent-arming-hardening (closed for the parked-pointer double-click and multi-gesture lures with the pointer parked, not eliminated): the consent page now uses the shared `Nebu.Web.ArmScript`; touch and keyboard residuals accepted, follow-up `cp`); no fencing token for the refresh lease (az);
a malformed `X-Forwarded-For` behind a trusted proxy falls back to the proxy bucket (ap4); a /48 holder owns 65 536 /64 sources (ao, at); an IdP without `auth_time` makes `/account`
destructive actions unavailable (release note aw); switch-off suspends instead of revoking (ai, runbook: `revoke_all_oauth_sessions/0`); one internal secret for all secrets at rest (al).

**Deferred.** (al) SecretBox v2 (HY17), (o) rotated-row cap (bs), (t) IdP-side revocation, PROXY protocol for TCP-mode load balancers (ap3), a dedicated admin hostname (ba),
scheduled key rotation (bq), batched revoke of very large clients (bb), revoke-all UI (bc).

**(s) re-scoped (decision 2026-10-13).** `device_lists.changed` on device deletion is NOT implemented: Nebu refuses encrypted rooms (ADR-011), so no peer encrypts to a
device, and the design (a new change-log table, a `/sync` token change) is risky. The gate moves from "before `oauth_enabled`" to "before encrypted rooms are allowed
(ADR-011 lifted) and before any release that claims E2EE"; the story `device-lists-changed-on-deletion` stays in the backlog (reserved ids bv, bw, bm-bo). This supersedes the open set
quoted in the story-9 update of the Gate items section.

**Activation readiness.** No code gate of the preconditions table is open in the server. What remains is operator work and the written acceptance of the residuals that fail closed until done: configure and test
`NEBU_TRUSTED_PROXY_CIDRS` with BOTH the negative spoof test and the POSITIVE test (two clients on different networks show distinct real `last_seen_ip` values through the real public path; a precondition of the flip), the load balancer / IdP / client / browser checks and the rotation, revoke and rollback rehearsals, grouped in
`docs/architecture/07-deployment.md` ("Manual verification before activation"), plus the SO7 / SO8 decision and the release notes above.

**Client-IP positive test (G3-2).** A correct trusted-CIDR list with a load balancer that does not append the client address passes every spoof test and still collapses all clients into the LB's bucket: every per-IP bucket and every per-source cap (consent 20 per source and 5 per user, authorize / account login requests 300, pending registrations 100) becomes global, so one anonymous source (for example 600 `GET /oauth2/authorize` per hour) can lock every user out of OAuth login. This is safe against spoofing but NOT for availability. `tofu alb` with an empty `lb_real_ip_cidrs` = do NOT flip `oauth_enabled`.

**Epic SEC gate 3 (2026-10-13).** Verdict: dormant merge PASS; activation blocked on G3-2 (docs / operator, gating positive test), the manual verification groups A-F and the written acceptance of the residuals; G3-3 (legacy SSO `redirectUrl` trust) was blocking at the time of the review and is CLOSED in the server afterwards by the story legacy-sso-redirect-confirmation (confirmation page + allowlist; manual verification group F); G3-1 (the revoke's lock waits behind a long client revocation) is closed by the bugfix `revoke-lock-bounds`. LOW items: G3-4 (the (s) re-scoping is now worded the same in follow-ups, 07-deployment and 11-risks; ADR-011 notes that lifting the encrypted-room refusal is blocked on `device-lists-changed-on-deletion`), G3-5 (reduced by story consent-arming-hardening, closed for the parked-pointer lures), G3-6 (the root `docker-compose.yml` is a dev file; its admin re-auth opt-out must never be set in production). Report: `docs/stories/oauth-broker/security-reports/epic-oauth-broker-security-review-gate3-2026-10-13.md`.

**SEC delta gate over the three G3 stories (2026-10-14).** Kassandra's cross-story review of the stories legacy-sso-redirect-confirmation, client-ip-misconfiguration-warnings and consent-arming-hardening: CLEAN, 1 MEDIUM, 3 LOW. X-1 (MEDIUM): the admin writers of the legacy-SSO trust lists (`sso_redirect_allowed_origins`, `sso_extra_redirect_schemes`) needed only a session and the Phoenix CSRF token, which a same-origin script (SO7) obtains with a `fetch()`: story `sso-origins-admin-hardening` puts both saves behind the E-3 gate (`OAuthAdminHelpers.gate(conn, :marker, "/admin/config")`: strict fetch metadata, then the fresh re-authentication marker bound to `/admin/config` and consumed by a successful save; SO4 allowlists the return path) and serves `/admin/config` unframed (`frame-ancestors 'none'`, `X-Frame-Options: DENY`, `no-store`, decided on `path_info`). X-4: the source-3 path trust refuses `;` and `%25` in the path. X-2 / X-3 are documentation (X-3: the G3-2 collapse already affects the legacy confirm page from the merge on, follow-up `cv`). X-6: a same-origin script needs no user click on the consent page or the SSO confirmation page (SO7 / SO8). The sibling forms (claim / role mapping, scopes) are follow-up `cw`. Reports: `docs/stories/oauth-broker/security-reports/epic-oauth-broker-security-review-gate3-delta-2026-10-14.md` and `.../sso-origins-admin-hardening-security-review-2026-10-14.md`.

## Admin UI switch (story admin-oauth-switch)

Owner requirement (2026-10-14): "for `oauth_enabled` I need a checkbox in the OIDC settings of the Admin UI, otherwise I cannot activate it
later on my running instance on UpCloud." Before this story the keys `oauth_enabled` and `oauth_issuer_url` could only be written with SQL.
Decisions `AS1`-`AS12` (prefix `AS`, no collision with D/T/R/C/A/V/TP/AH/FR/CR/SO/LL/RU/HY). No migration (both keys are in the
`config_update_mutable` allowlist since 000040 / 000042 / 000048). The default of `oauth_enabled` is untouched (absent = off).

- **AS1 (where).** Section "OAuth 2.0 authorization server" on `/admin/config` (form `#oauth-switch-form`, `POST /admin/config/oauth-switch`,
  `ConfigController.save_oauth_switch/2`); the path segment `oauth-switch` is one of the unframed config segments of the router (SO6 rules:
  `frame-ancestors 'none'`, `X-Frame-Options: DENY`, `no-store`). `dev/tls/oauth.sh` stays (the same two keys by SQL).
- **AS2 (fields).** hidden `oauth_enabled=false` followed by the checkbox `oauth_enabled=true`, the text field `oauth_issuer_url`, the checkbox
  `oauth_activation_ack`. Only the exact values `true` / `false` are accepted for the switch: anything else (a list, a map, `on`, `1`, absent) is an
  error on that field, never a silent "off".
- **AS3 (issuer).** Validated by the runtime function (`Nebu.OAuth.Metadata.normalize_issuer/1`, reached as `Nebu.OAuth.normalize_issuer/1`:
  https, a host, no userinfo / query / fragment, empty path) plus form-only rules that are stricter and never looser: no whitespace or control
  characters inside, an ASCII host (punycode) or a bracketed IPv6 literal, an optional numeric port 1..65535 (`URI.parse` reads `https://host:` and
  `https://host:abc` as the default port), at most 255 bytes. A non-empty invalid issuer is refused also while off; the empty string is stored only while
  off (the runtime reads it as "no issuer"). `Nebu.OAuth.SwitchStore` re-checks (defence in depth) and never persists "on" with an issuer the runtime
  would read as "off". A valid but wrong issuer is served as written (the status list warns when its host differs from `NEBU_SERVER_NAME`).
- **AS4 (protection = the SSO trust lists, no third mechanism).** `OAuthAdminHelpers.gate(conn, :marker, "/admin/config")` after `require_admin` and
  the CSRF check and before validation: strict fetch metadata (WebKit: the click proof of SO9, a notice page instead of a 403) and a fresh
  re-authentication marker bound to `/admin/config` (SO4, single use, consumed after a SUCCESSFUL write only). BOTH directions are protected: a
  same-origin script (SO7) that switches OAuth off is an availability attack on every OAuth client. The always-available emergency path is the SQL
  rollback (07-deployment), also when the IdP is down and no fresh sign-in is possible.
- **AS5 (acknowledgement).** When the result is ON and differs from the stored state (the switch turns on, or the issuer changes while on, also from
  a stored "on" with an invalid issuer), and whenever a non-empty issuer is set or changed while the switch stays off (the issuer origin is a trusted
  `redirectUrl` of the legacy SSO login, source 2 of L3, also with OAuth off: Kassandra M-1), the checkbox "I have read the activation checklist ..." must be ticked (a validation error otherwise: 200
  re-render, nothing written, marker kept). Switching off needs none. The page names the checklist, the rollback (uncheck and save), the cache
  window and that running OAuth sessions stay valid after switching off until their access token expires (C16, `revoke_all_oauth_sessions`).
- **AS6 (no change).** Equal normalized values write nothing, audit nothing and keep the marker.
- **AS7 (audit, atomic, asymmetric).** One `audit_log` row `oauth_switch_changed` per change (actor, `enabled_before` / `enabled_after`, `issuer_before` /
  `issuer_after`, `reauth` kind), written by the caller's audit function INSIDE the transaction of the two upserts (`Nebu.OAuth.SwitchStore`,
  the carve-out pattern of the OAuth client decisions, `AuditWriter` moduledoc): a change is unaudited only through `unaudited_ok` and an audit row never describes a change
  that did not happen. A failing or raising audit function rolls both upserts back. Asymmetry (`unaudited_ok`): a change whose RESULT is ON is refused
  without its audit row ("not saved"), a change whose result is OFF with the issuer unchanged or cleared (the kill switch) is retried once WITHOUT the audit function
  (setting or changing an issuer widens the legacy-SSO trust and always needs its audit row), with one value-free ERROR log and a flash that says the audit entry is missing: the kill switch is never blocked by an unwritable audit table.
- **AS8 (cache, bounded staleness).** After the commit the saving node drops its own entry of the per-node switch cache
  (`Nebu.OAuth.Config.invalidate_cache/0`), so it answers with the new state at once; every other node follows within `NEBU_OAUTH_CONFIG_CACHE_MS`
  (HY2, the same bounded-staleness exception to ADR-020). A read that started before the commit can refill the cache with the old value for at most
  one TTL (accepted). Two admins saving at once: last write wins, each audited with the "before" values of its own read (follow-up `dc`).
- **AS9 (status, non-blocking).** `Nebu.Admin.OAuthSwitch.status/2` derives, for the page, what the server can see: the stored switch; whether THIS
  node answers `auth_metadata` 200 now (`oauth_aware?/0`) and a propagation note otherwise; `NEBU_TRUSTED_PROXY_CIDRS` empty (G3-2: every per-IP limit
  global behind a proxy); the issuer host against `NEBU_SERVER_NAME`; `matrix_oidc_refresh_mode` online with `per_refresh` revalidation; an insecure
  admin session; the re-authentication opt-out. Each item carries the word `OK`, `Attention` or `Note`. It never says that a precondition the server cannot
  see is met (load balancer, the positive client-IP test, the IdP's `auth_time`, the clients, the manual groups A-F): the page says so in a standing text.
- **AS10 (layering).** `Nebu.OAuth.save_switch/2`, `normalize_issuer/1`, `config_cache_ms/0` are the only entry points the Admin domain uses (ADR-020);
  the SQL is inline in `Nebu.OAuth.SwitchStore` (ADR-018). The transaction function is a test seam (`:oauth_switch_tx`, test builds only).
- **AS11 (not changed).** The runtime predicate (`Config.live_state/1`), the fail-closed behaviour with an invalid stored issuer, the other `oauth_*` keys
  (SQL only, follow-up `db`) and SO7 (the shared origin stays the accepted residual; SO8 is the fix).
- **AS12 (accessibility).** Every control has a label, the status items start with a word (never colour only), validation errors are `role="alert"` with
  `aria-invalid` / `aria-describedby`, the saved notice is the page flash, the section reflows at 320 px.

Manual verification: 07-deployment group D ("OAuth switch checkbox flow"): per browser (Safari, Firefox, Chrome), on a running instance, with the rollback.

## Legacy SSO redirect confirmation (epic SEC gate 3 G3-3, story legacy-sso-redirect-confirmation)

Context. Legacy `m.login.sso` accepted ANY https `redirectUrl` and handed the `loginToken` of the verified IdP login to it (no client, device id or consent; independent of `oauth_enabled`; the E-2 closure of the OAuth path did not cover it). The Matrix spec says homeservers SHOULD confirm with the user before granting access to the site named in `redirectUrl` (before redirecting or after login, in the callback) and MAY allowlist known-trusted URLs. Decision (owner, 2026-10-13): implement the Synapse model including the behaviour change for legacy clients. Short form of the story's decisions (D1-D20):

- **L1 Classification (D1, D2).** One module, `Nebu.Matrix.SsoRedirect.classify/1`, decides `:direct` (loopback http, default deep-link schemes, operator schemes: unchanged), `{:https, target}` (confirmable) or `{:reject, reason}` (the unchanged `400` bodies). It does NOT rely on `URI.parse/1` for the decision: parser differentials between `URI.parse/1` and browsers were open redirects before (`http://evil\@localhost/`, `https:evil`, `https:\\evil`). Rejected: userinfo, backslash in the authority, control characters and whitespace, hosts outside `[a-z0-9-.]` labels, trailing dot, IPv6 literals, numeric-looking hosts that are not canonical dotted decimal, more than 2048 bytes. `@` / `%` after the authority (Element Web fragments) are fine.
- **L2 Placement (D3).** After the IdP login, before any `loginToken` exists: an unlisted https target gets a pending confirmation and a `303` to `GET /_matrix/client/v3/login/sso/confirm` (PRG, nothing of the IdP code or state in the URL), the POST decides. Continue mints the `loginToken` (30 s, as before) and answers `303` with the unchanged `append_login_token/2` (plus: existing `loginToken` parameters are removed, spec "should"). Cancel consumes without a token. The route is a Nebu extension under `/_matrix/client/v3/login/sso/` (already proxied; 405 / 404 `M_UNRECOGNIZED` for other methods and sub-paths).
- **L3 Allowlist (D4-D6).** Exact origin match, first hit wins, fail closed: (1) `https://<server_name>` (NOT the `Host` header), (2) the origin of `oauth_issuer_url`, (3) the registered https redirect URIs of OAuth clients in status `approved` (the URI and the paths below it, NOT the whole origin) (through the facade `Nebu.OAuth.trusted_redirect_url?/2`, ADR-020; 500 ms bound, any error = not listed, one value-free WARNING), (4) the operator list `server_config.sso_redirect_allowed_origins` (Admin UI `/admin/config`, ADR-022: no env variable; same `Nebu.Web.OidcConfig` cache and cluster refresh as `sso_extra_redirect_schemes`). Wildcards, paths and non-https entries are refused at save time; a successful save writes the audit action `sso_redirect_origins_changed`. Source (3) matches by REGISTERED URI, not by origin (Kassandra cycle 0 #1): the redirectUrl must equal a registered https `redirect_uri` of an approved client or extend it at a path boundary (`/`, `?`, `#`), because a legacy `loginToken` is a full unscoped session while an OAuth code is scoped and consent-gated; dot segments and encoded separators never match.
- **L4 Pending entry (D7).** `Nebu.Matrix.SsoStore` tag `:confirm` (key = raw SHA-256 of the binding cookie, TTL 5 min, cap 10 000, pg replication, single-use `pop` BEFORE minting; `format_status/1` redacts state and messages). Every SsoStore call catches `GenServer.call` exits (`{:error, :unavailable}` / `:error`, a throttled tag-only WARNING) so that a timed-out call can never put the id_token or IdP refresh token into the request process's crash report (Kassandra cycle 0 #2). Recorded deviation from "single-use consumption is atomic SQL": cross-node single use is best effort exactly like the `loginToken` store, bounded by the binding cookie (a second node can only serve the legitimate browser) and by the 5 min TTL; no migration table.
- **L5 Page hardening (D8, D9, D15).** As the consent page: `__Host-` binding cookie (plain-http fallback), CSRF derived from the cookie, constant-time compares, Origin + lenient fetch metadata, rate limits that follow the binding cookie (a per-binding bucket for live entries, a per-address miss bucket for unknown cookies, nothing for a missing / malformed cookie: story sso-confirm-bucket-order, L9), `X-Frame-Options: DENY`, CSP `frame-ancestors 'none'` and a `form-action` built only from the parsed target origin (Chromium applies it to the redirect after the POST), `no-store`, `Referrer-Policy: same-origin` on the page (a `no-referrer` page would make its own POST `Origin: null`). **No `Cross-Origin-Opener-Policy`** anywhere in this flow (oracle M1: it would cut `window.opener` of popup clients such as FluffyChat web). The shared ES5 arming script (`Nebu.Web.ArmScript`: pointer move + 600 ms, a pointer movement onto Continue after arming for mouse and pen, a touch path, keyboard) is the double-click-jacking defence and is now also used by the consent page (story consent-arming-hardening, G3-5, FR21), which keeps its COOP.
- **L6 Migration 000048 (D13).** Re-creates `config_update_mutable` with the 000042 list plus `sso_extra_redirect_schemes` (a pre-existing gap: the second save raised an RLS error) and `sso_redirect_allowed_origins`.
- **L7 Logging (D12).** INFO `matrix SSO: redirect confirmation shown|confirmed|declined host=<host>` (host only: it tells the operator which origins to list); never a loginToken, id_token, cookie, CSRF token, confirm key, path, query or fragment from the callback onward. The redirect leg's DEBUG line keeps `redirectUrl` (follow-up `ce`).
- **L9 Counting by the binding cookie (story sso-confirm-bucket-order, follow-up `cv`, SEC delta gate X-3).** The page used to charge `{"sso_confirm", ip}` (600/h) on every GET / POST before it
  looked at the cookie, so with the G3-2 collapse (the `alb` topology with an empty `lb_real_ip_cidrs`: one shared address) one anonymous source answered `429` for every user of an unlisted web origin.
  Now the cookie decides: none / malformed -> `400 invalid_state`, nothing charged, the store not asked; a well-formed cookie -> `SsoStore.peek_confirm/1`: a HIT (live entry) is charged to the PER-BINDING
  bucket `{"sso_confirm", hex(SHA-256(cookie))}` (refill 2/min, burst 60, GET and POST share it), a MISS (unknown, expired, consumed) to the PER-ADDRESS miss bucket `{"sso_confirm_miss", ip}` (the old 600/h):
  the miss bucket can deny only requests that carry an unknown cookie, never a user with a live entry. A cookie-less POST is `invalid_state` whatever its body or Origin (a MISSING cookie is not cleared, a malformed one is: a cross-site top-level POST carries no `SameSite=Lax` cookie and must not delete the user's, SEC L-1) (the earlier order answered
  `429` / `400 invalid_request` / `403` first); a POST with a live cookie keeps parse -> decision -> Origin + fetch metadata -> CSRF -> pop. Residual: a flood of well-formed random cookies still
  reaches the node-local `SsoStore` (an O(1) lookup, bounded call timeout; the miss bucket throttles the ANSWER, not that lookup, which must run first to tell a hit from a miss; an unreachable store counts as a miss) and fills its source's miss bucket; a signed binding cookie would avoid the lookup (follow-up `di`).
- **L8 Residuals (D18, D19).** Loopback and custom-scheme targets stay unconfirmed (a local process or app on the user's device); the page is a warning, not proof; `https://<server_name>` must be operator controlled (`.well-known` delegation); approving an OAuth client also trusts its registered https redirect URIs (and the paths below them; a path containing `;` or `%25` never matches) for the legacy flow; no pre-redirect browser binding (login CSRF, `ca`); Continue needs JavaScript; the 30 s `loginToken` lifetime exceeds the spec's "around five seconds" (native protocol handlers need it); an unknown `{idpId}` is redirected, not `404`.

## Operations note: migration 000040 was edited in place

Migration `000040_oauth_clients_and_auth_metadata` is not released yet and was edited in place
during the review cycles of this story (INSERT policy, guard trigger, decision CHECK, host column).
A database that already applied an EARLIER shape of 000040 does not get the final shape from a
re-run and must be reset: drop the volume, or run the down migration and then the up migration
again (this discards all OAuth client registrations, which only exist in dev/CI at this point).
Once 000040 is released, schema changes go into a new migration.

## Implications: legacy coexistence is temporary

The legacy login, `POST /refresh` and the background token-refresh workers keep working for sessions
created the old way: both mechanisms run in parallel (decision 6; story 5). Every `matrix_sessions` row
carries `auth_api` (`legacy` | `oauth`) and a session only ever uses the API that issued it. Coexistence is
temporary: what happens when one of the two is deprecated is recorded in C20 above (deprecating legacy
adds a `legacy_login_enabled` switch and removes `/refresh`, the workers and the raw-JWT path; deprecating
OAuth is `oauth_enabled = false`). Nothing in this ADR removes either API.
