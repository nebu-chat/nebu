# 8 Cross-Cutting Concepts

## Authentication and Authorization

**OIDC-only (no local accounts):** Every user authenticates via an OIDC-conformant provider
(Keycloak, Azure AD, Dex, Google). No local passwords, no shadow directory.

**Token flow (single Elixir application, ADR-021):**
```
Matrix Client → Nebu (Nebu.Web.Plugs.OidcPlug):
  Authorization: Bearer <oidc_token>
  → OidcPlug validates the token against the cached OIDC JWKS (signature + exp + iss + aud + sub)
  → extracts: user_id (@sub:server.name), system_role
  → consults the token denylist (revoked tokens) and provisions the user row idempotently

OidcPlug → domain (in-process):
  conn.assigns.current_user = "@user:server.name"  (+ access_token, oidc_claims)
  the Matrix handlers call the domain functions directly — no metadata hop, no separate process
```

There is no Go layer in front of the application; **the OIDC plug is the single auth + provisioning
point**. Token revocation, rate limiting, and security headers are all enforced in `Nebu.Web` on the
same node.

Components in `Nebu.Web` (the shared HTTP plumbing):

- **`Nebu.Web.Plugs.OidcPlug`** — extracts `Authorization: Bearer`, enforces a strict asymmetric
  `alg` allowlist (`RS*/ES*/PS*` only — `alg:none` and HMAC `HS*` are rejected before any key
  selection, blocking alg-confusion attacks, MEDIUM-2), selects the JWK by the token `kid`, and
  verifies signature + `exp` + `iss` + `aud` + `sub` via `Assent.JWTAdapter.verify/3`. Issuer and
  audience are validated **fail-closed**: a missing `oidc_issuer`/`oidc_audience` config rejects
  every token rather than failing open (MEDIUM-3). After a token cryptographically verifies, the plug
  consults `Nebu.Web.TokenDenylist` (see below) and rejects a revoked token. On success it assigns
  `conn.assigns.current_user = "@<sub>:<server_name>"` (plus `access_token` and `oidc_claims`, so
  `POST /logout` can revoke exactly the token that authenticated the request) and idempotently
  provisions the user row (TTL-cached, 60s, kept off the `/sync` hot path). On failure it returns a
  Matrix-error JSON envelope (`M_MISSING_TOKEN` / `M_UNKNOWN_TOKEN`) and halts. The verification core,
  `OidcPlug.verify_token/2`, accepts optional `:issuer` and `:jwks` overrides; only the bootstrap
  operator-login callback passes them (to verify against the bootstrap draft's issuer + locally-fetched
  keys before `server_config` exists). All checks remain fail-closed and the single verification code
  path is preserved — the overrides change only where the issuer/keys come from, not the validation.
- **`Nebu.Web.TokenDenylist` (logout revocation, F-1)** — OidcPlug returns the verified OIDC token
  verbatim as the `access_token`, so destroying the session GenServer alone would NOT stop the token
  from re-validating on the next request; without a denylist, logout would be a no-op until the token's
  own `exp`. `POST /logout` adds the presented token to this denylist; OidcPlug consults it on every
  authenticated request (after crypto verification, so an attacker cannot flood it with unsigned
  strings) and rejects a revoked token with `401 M_UNKNOWN_TOKEN`. Entries are keyed by the JWT `jti`
  claim when present, otherwise by the SHA-256 hash of the raw compact token (Go `pgTokenHash` parity;
  the raw token is never stored), and self-expire at the token's `exp` (lazy delete on lookup, so the
  table cannot grow unbounded). **Persistence strategy (fix-jwt-denylist-persistence):** ETS is a
  write-through cache; the pre-existing PostgreSQL `invalidated_tokens` table (`token_hash TEXT PRIMARY
  KEY, expires_at BIGINT`) is the persistent truth source. `revoke/3` writes to ETS and then to DB
  (best-effort — logs a warning on failure, never crashes). `revoked?/2` checks ETS first; on a miss it
  falls back to a DB `SELECT` so tokens revoked before a node restart are still rejected after ETS is
  cleared. DB keys use a flat-string encoding disjoint from ETS tagged tuples: `"jti:<value>"` for
  jti-keyed entries, bare 64-char SHA-256 hex otherwise. DB results are not back-populated into ETS
  (write-through only — avoids stale-cache issues in rolling-restart / multi-node scenarios).
- **`Nebu.Web.Plugs.RateLimit` (per-IP rate limiting, F-3)** — a classic per-IP token-bucket limiter
  (ETS), porting the Go gateway's `NewIPRateLimiter`/`strictRL` so the brute-force / verification-DoS
  controls survive the migration. `POST /login` is limited to 30 req/min burst 10 (Go `strictRL`
  parity); the long-poll `GET /sync` to a generous 600 req/min burst 100 (caps a single IP hammering
  the endpoint to exhaust BEAM long-poll processes without impeding a normal client). On exhaustion it
  responds `429` with the Matrix envelope `{"errcode":"M_LIMIT_EXCEEDED","error":"Rate limit
  exceeded"}` plus a `Retry-After` header and halts. The bucket key is `conn.remote_ip` (the directly
  connected peer — no trusted-proxy/XFF config yet, so the safe default: a client cannot spoof its own
  bucket key). Buckets are volatile ETS (reset on restart — a restart cannot bypass a sustained attack
  because the steady-state rate still bounds throughput). `NEBU_RATE_LIMIT_DISABLED=true` makes it a
  no-op (test/dev escape hatch, mirroring the Go gateway flag).
- **Security header (F-5)** — `Nebu.Web.Router` registers a `before_send` callback at the front of the
  pipeline that sets `X-Content-Type-Options: nosniff` on **every** response — including those produced
  by the forwarded sub-routers and CORSPlug's halted preflight. All Nebu responses are
  `application/json` Matrix envelopes, so this prevents any MIME-sniffing edge case on a misbehaving
  client.
- **`Nebu.Web.OidcConfig`** — a GenServer + ETS cache for OIDC issuer, audience, and JWKS URI.
  **ADR-022: OIDC is configured EXCLUSIVELY via the Bootstrap Wizard** (`server_config`) — there is no
  environment-variable OIDC config path. `OidcPlug`, `JwksCache`, `SsoLogin`, and `Admin.Auth` resolve
  issuer/audience/JWKS-URI **solely** through this cache (and the bootstrap draft during the wizard flow).
  Caching in ETS `:nebu_http_oidc_config` avoids per-request DB lookups on the hot OIDC path. The cache is
  refreshed by the Bootstrap Wizard after configuration is written to `server_config`, and cluster-aware
  invalidation via `:pg` ensures all nodes stay synchronized (ADR-020, M-3). When `server_config` has no
  OIDC config (pre-bootstrap), the cache returns `nil` and every consumer **fails closed** (F-4 — all
  Bearer tokens rejected with 401; admin → `/bootstrap`). A test-only `:oidc_config_source` seam injects
  values without a live DB.
- **`Nebu.Web.JwksCache`** — a GenServer that fetches the OIDC provider JWKS on start and refreshes
  it on a TTL (`NEBU_OIDC_JWKS_TTL`, default 300s — a cache-tuning knob, not OIDC config). The JWKS URI
  is resolved (ADR-022) from `server_config` via `OidcConfig.jwks_uri/0`; when only the issuer is
  configured (no explicit JWKS URI) it is auto-discovered from the issuer's
  `/.well-known/openid-configuration` document. The discovered `jwks_uri` is validated to use `https://`
  or `http://` scheme only (SSRF guard). On a refresh failure it keeps the last-known-good keys rather
  than blanking the cache, so transient JWKS outages do not reject otherwise-valid tokens. The JWKS HTTP
  fetch uses TLS peer verification for `https` endpoints. Its state is volatile and is recovered by a
  fresh fetch when the supervisor restarts it. A public helper `JwksCache.fetch_keys_for/2` performs an
  explicit, TLS-verifying fetch for a given `jwks_uri`/`issuer` **without mutating the global cache** —
  used by the bootstrap operator-login callback so it can verify an ID token against the bootstrap
  draft's keys before `server_config` exists, without warming the global cache and thereby breaking the
  fail-closed-until-bootstrap-completes invariant (F-4).
- **Router scoping** — `Nebu.Web.Router` keeps `GET /health` open, forwards the unauthenticated Matrix
  routes (`POST /login`, `GET /profile`, MSC2965 discovery) to `Nebu.Matrix.HttpPublic`, and forwards
  everything else under `/_matrix` to the protected sub-router `Nebu.Matrix.Http.Protected` whose
  pipeline runs `OidcPlug`.

Both request-time ETS tables (token denylist, rate-limit buckets) are created eagerly at
`Nebu.Application` boot so the lazy `ensure_table` fast path never has to race under concurrent
first requests (closing a brief fail-open window, R-2). **Config validated per-operation, not at boot
(ADR-022):** `runtime.exs` reads no OIDC config — the server boots without OIDC and fails closed until
the Bootstrap Wizard writes `server_config`. `NEBU_DB_URL` and `NEBU_PII_ENCRYPTION_KEY` remain
mandatory at boot. When `server_config` has no OIDC config, OidcPlug fails closed (F-4) and rejects
all Bearer tokens with 401; the wizard validates required fields (issuer, single client id/secret,
audience, JWKS URI) at form submission to prevent completing into a broken state.

Relevant configuration (server service): all OIDC config (issuer, audience, JWKS URI, the single
client id/secret, claim mappings) is set via the **Bootstrap Wizard** (`server_config`), never env.
Remaining env knobs: `NEBU_OIDC_JWKS_TTL` (JwksCache refresh interval), `NEBU_OIDC_DISPLAY_NAME`
(advertised IdP name for `POST /login` `m.login.sso`), `NEBU_SSO_REDIRECT_SCHEMES`,
`NEBU_RATE_LIMIT_DISABLED`, and `NEBU_SERVER_NAME` (used to build the `@<sub>:<server_name>` Matrix
user ID and to derive the admin `/admin/callback` redirect_uri).

**Bootstrap mode:** First OIDC login automatically receives `instance_admin`. Bootstrap mode is
permanently disabled after the first admin setup. No default password, no insecure fallback.

**Single OIDC client (ADR-022):** ONE OIDC client serves both Matrix Bearer-token validation and the
admin operator login. The wizard configures it (`server_config.oidc_client_id` + AES-256-GCM-encrypted
`oidc_client_secret`); the IdP-side client registers all Nebu redirect URIs (Matrix SSO redirect,
Element `auth.html`, and `/admin/callback`). There is no separate admin client and no env credential
fallback — `SsoLogin.resolve_client_credentials/0` and `Admin.Auth.oidc_config/1` read the single
client from `server_config` only (or the bootstrap draft during the wizard flow), decrypting the
at-rest secret on use. The admin `/admin/callback` redirect_uri is server-derived from `:server_name`
+ `:admin_session_secure` (never from request headers).

**OIDC scopes (ADR-022):** the admin/bootstrap authorization request asks for `openid` + the
operator-configured extra scopes (default: `profile email groups`); the Matrix SSO authorization
request asks for `openid` + operator-configured extra scopes (default: `profile email`). Both add
`offline_access` when their configured refresh mode is `"offline"` (read live from `server_config`
via the `:matrix_oidc_refresh_mode_reader` / `admin_oidc_refresh_mode` seams). `openid` is always
mandatory (cannot be removed); all other scopes are **operator-configurable** via the Bootstrap
Wizard and `/admin/config` (Story configurable-oidc-scopes, `server_config` keys
`matrix_oidc_extra_scopes` / `admin_oidc_extra_scopes`). There is no `NEBU_OIDC_EXTRA_SCOPES` env
var (ADR-022: bootstrap-only config).

A matching warning is emitted for `client_secret`. This ensures operators can detect a misconfigured
SSO flow immediately from startup logs before the first login attempt.

**`LoginHandler` API change:** `LoginConfig` gains two optional loader fields:

```go
ClientIDLoader     func(ctx context.Context) string  // nil = use static ClientID field
ClientSecretLoader func(ctx context.Context) string  // nil = use static ClientSecret field
```

`resolveClientID(ctx)` and `resolveClientSecret(ctx)` methods on `LoginHandler` delegate to the
loader when set, otherwise return the static fields. All usages in `sso.go` (`GetSSORedirect`,
`GetSSOCallback`) and `login.go` (`PostLogin` verifier) call these methods — the static-field
fallback preserves backward compatibility for test setups and deployments without a Bootstrap DB.

**Deployment-specific scope defaults (Bootstrap Wizard, no env var):**

| Client | Default extra scopes | Key in `server_config` |
|---|---|---|
| Matrix SSO | `profile email` | `matrix_oidc_extra_scopes` |
| Admin login | `profile email groups` | `admin_oidc_extra_scopes` |

`groups` in the admin default is required for Dex to release the groups claim used by `admin_group_claim` matching. Operators who remove it lose group-based admin assignment. These defaults apply on first-use (no row in `server_config`); Bootstrap Wizard writes explicit values; `/admin/config` allows runtime update without redeploy.

**Configurable OIDC Refresh Mode (Story oidc-refresh-mode-config):**

Whether the Matrix and Admin OIDC flows request a refresh token (`offline_access`) is **configurable
per client** rather than hardcoded. Two `server_config` keys, each `offline | online`, drive it:

| Key | Default | Builder reading it live | `offline_access` requested? |
|---|---|---|---|
| `matrix_oidc_refresh_mode` | `offline` | `Nebu.Matrix.SsoLogin.scope_list/0` | iff mode = `offline` |
| `admin_oidc_refresh_mode` | `online` | `Nebu.Admin.Auth.admin_oidc_scope/0` | iff mode = `offline` |

- **Set at bootstrap** (Bootstrap Wizard) **and changeable at runtime** via `/admin/config`
  (`Nebu.Admin.ConfigLive`). Runtime changes apply to **subsequent logins** — no redeploy.
- The scope builders read the mode **live** (per request, via an injectable
  `:{matrix,admin}_oidc_refresh_mode_reader`, default = `server_config` lookup). `openid` is always
  mandatory; `offline_access` is appended only when the client's mode is `offline`. Any
  operator-configured base scope (`:admin_oidc_scope`) and `NEBU_OIDC_EXTRA_SCOPES` are still honoured.
- The admin client **no longer force-requests `offline_access`** — its `online` default means no
  special IdP client approval is needed for standard admin sign-in.
- **IdP caveat:** **Dex** issues a refresh token *only* when `offline_access` is requested, so admin
  `online` mode disables silent refresh on Dex. **Keycloak** supports session-bound online refresh, so
  `online` mode there can still keep the session alive.

**Configurable OIDC Extra Scopes (Story configurable-oidc-scopes):**

Which OIDC scopes Nebu requests beyond the mandatory `openid` is **operator-configurable** per
client, set in the Bootstrap Wizard (Step 3, before refresh-mode) and changeable at runtime via
`/admin/config`. Two `server_config` keys drive it:

| Key | Default | Scope builder |
|---|---|---|
| `matrix_oidc_extra_scopes` | `profile email` | `Nebu.Matrix.SsoLogin.scope_list/0` |
| `admin_oidc_extra_scopes` | `profile email groups` | `Nebu.Admin.Auth.admin_oidc_scope/0` |

- **`openid` is always injected** by the scope builders — it cannot be removed by operator config.
- `offline_access` is still controlled by `{matrix,admin}_oidc_refresh_mode` (unchanged).
- Scope tokens are validated against `[a-zA-Z0-9_:.\-]+` (anchored with `\z` — trailing-newline
  safe) at every write boundary (bootstrap wizard, admin config page, bootstrap promotion).
- Migration `000013` extends the `config_update_mutable` RLS policy to include both new keys,
  mirroring the `000007` pattern for refresh-mode keys.
- Runtime injection via `:{matrix,admin}_oidc_extra_scopes_reader` seams (0-arity fun) mirrors the
  `:{matrix,admin}_oidc_refresh_mode_reader` pattern for test isolation.

**Configurable Nebu session-lifetime ceiling (Story e2e-session-refresh-suites):**

The Nebu-controlled session ceiling — the Matrix opaque-session expiry (`min(oidc_exp, ceiling)` on
login and the `/v3/refresh` re-mint) and the admin session cap — defaults to **8h**, read through
`Nebu.Web.SessionConfig.{matrix,admin}_session_ttl_seconds/0`. Operators may shorten it at boot via
`NEBU_MATRIX_SESSION_TTL_SECONDS` / `NEBU_ADMIN_SESSION_TTL_SECONDS` (parsed by
`SessionConfig.parse_ttl/1`: only a strictly-positive integer applies; unset/junk/≤0 → the 8h
default, never crashes the login path). This is primarily a **test seam** — `make test-e2e-refresh`
sets a short TTL so the silent-refresh loop fires within a browser-test window — and is inert in
production unless explicitly set. The login ceiling stays bounded by the OIDC `exp`; the `/v3/refresh`
re-mint remains `now + ceiling` (the pre-existing trade-off, now configurable). Migration `000007`
adds `matrix_oidc_refresh_mode` / `admin_oidc_refresh_mode` to the `server_config`
`config_update_mutable` RLS allowlist so the refresh-mode runtime change (above) actually persists
after bootstrap (the keys are enum-validated `offline|online` at every write — no scope injection).

**SSO Nonce-Based Replay Prevention (Story 11-7, hardened Story 12.7):**

`GetSSORedirect` generates a 16-byte cryptographically random nonce (32 hex chars) per SSO
flow. The nonce is stored in `globalSSOState` alongside the PKCE verifier and forwarded to
Dex via `oauth2.SetAuthURLParam("nonce", nonce)`. In `GetSSOCallback`, the `nonce` claim is
extracted from the returned id_token and compared against the stored nonce using
`crypto/subtle.ConstantTimeCompare` (timing-attack safe, Story 12.7 LOW-7). A mismatch results
in `403 M_FORBIDDEN "SSO nonce mismatch"` - no loginToken is issued. The server nonce is
never logged on mismatch (Story 12.7 LOW-8). This prevents Dex's server-side token caching
from replaying a previously invalidated JWT as a new access_token.

**Denylist Check at Login (Story 11-7):**

`PostLogin` calls `h.store.IsInvalidated(rawJWT)` before issuing an access_token. If the
submitted JWT is in the denylist, it returns `403 M_FORBIDDEN "Token has been logged out"`.
This is defence-in-depth against direct `POST /login` calls that submit a previously
invalidated JWT (bypassing the SSO nonce check). Status `403 M_FORBIDDEN` (not `401`) is
intentional: `POST /login` is an authentication *attempt*, not a session validation request.
`LoginHandler.store` is nil-safe - deployments without a denylist skip the check.

**Deactivated User Login Rejection (Story 14.4):**

`PostLogin` calls `validate_token` (in-process) which checks `is_active` in the DB. When the Elixir
domain returns `:permission_denied` with message `"user account is deactivated"`, `PostLogin`
responds `403 M_USER_DEACTIVATED` (Matrix CS API v1.18 required errcode). This covers the
case where a user was deleted via GDPR erasure but attempts to re-authenticate via OIDC.
All other `validate_token` errors remain `500 M_UNKNOWN` (defensive - no internals leaked).

**Cache-Control: no-store on SSO Redirect (Story 11-7):**

`GetSSORedirect` sets `Cache-Control: no-store` before the `http.Redirect` call. This
prevents Safari (and any intermediate cache) from storing the 302 redirect response. Without
this header, Safari can replay a cached redirect on re-login, causing the already-consumed
state parameter to be rejected (`400 M_UNKNOWN "Invalid or expired SSO state"`).

**Rate limiting (per IP) - API Gateway:**

| Tier | Rate | Endpoints |
|---|---|---|
| strict | 30/min, burst 10 | `POST /login` (brute-force risk) |
| compliance | 10/min, burst 10 | All compliance/* and admin key/anonymize |
| admin | 60/min, burst 20 | Login UI, bootstrap wizard |
| medium | 30/min, burst 10 | SSO redirect/callback, public profile |
| loose | 300/min, burst 100 | Discovery, capabilities, unauthenticated stubs |

Implementation: `Nebu.Web.Plugs.RateLimit` - a per-IP token-bucket limiter backed by ETS, keyed on `conn.remote_ip` (the directly connected peer, not a spoofable `X-Forwarded-For`). The buckets are volatile ETS (reset on restart; steady-state rate still bounds throughput). `NEBU_RATE_LIMIT_DISABLED=true` makes it a no-op (test/dev). The tier values above are historical Go-gateway tiers; the consolidated app enforces equivalent limits in-process (e.g. `POST /login` 30/min, `GET /sync` 600/min).

**Rate limiting (per IP) - media endpoints:**

The media endpoints are guarded by the same `Nebu.Web.Plugs.RateLimit` token-bucket limiter as the
rest of the Matrix API (e.g. `preview_url` 30/min, `upload` 600/min). The limiter keys on the peer IP
(`conn.remote_ip`), not a client-supplied `X-Forwarded-For`, so an attacker cannot rotate the bucket
key. On exhaustion it returns `429` with `{"errcode":"M_LIMIT_EXCEEDED",...}` + `Retry-After`.
`NEBU_RATE_LIMIT_DISABLED=true` disables it (dev/test escape hatch). (Historically these limits lived
in a standalone Go media gateway with a `sync.Map` limiter and a `NEBU_TRUSTED_PROXY` gate; the Go
media service is gone — ADR-021.)

## Media Served In-Process by the Elixir Application (ADR-021)

Media handling lives in `Nebu.Media.*` and serves the Matrix `/_matrix/media/v3/*` and
`/_matrix/client/v1/media/*` endpoints (upload, download, download/{fileName}, thumbnail, preview_url)
on the same Bandit/Plug pipeline behind `OidcPlug`. There is no separate media process. The
cross-cutting controls are:

- **At-rest encryption (AES-256-GCM, ADR-011 managed E2EE key escrow):** `Nebu.Media.Crypto`
  encrypts every media object with AES-256-GCM. The per-object AES key + nonce are stored hex in the
  `media_files` table (key escrow — operator/server can decrypt, consistent with ADR-011's managed
  model). The encryption is byte-compatible with the prior Go implementation. Because GCM authenticates
  the whole blob, **download decrypts the entire object in memory** and then serves it (including HTTP
  Range responses) over the decrypted plaintext.
- **Access control = local OTP/DB call (no gRPC):** `Nebu.Media.Membership` checks `room_members`
  via inline SQL inside the same node, replacing the former gRPC `CheckMembership` RPC — one fewer
  cross-process hop. Note: `media_files` has no `room_id`, so the current check is *member-of-any-room*;
  per-media room scoping is a documented accepted follow-up.
- **Object storage = ExAws.S3 against MinIO (ADR-013):** `Nebu.Media.Storage` uses `ExAws.S3`.
  New deps: `ex_aws`, `ex_aws_s3`, `finch`, `floki`, `sweet_xml`, `hackney`. A Finch pool is started in
  `Nebu.Application`. `server/config/runtime.exs` reads the MinIO credentials from file-based Docker
  secrets.
- **SSRF guard for outbound preview fetches:** `preview_url` (`Nebu.Media.HttpFetch`) fetches the
  target page via Finch and parses Open Graph tags with Floki. `Nebu.Media.SSRF` guards the outbound
  request: a scheme allowlist plus blocking of loopback, RFC1918, link-local, CGNAT, cloud-metadata,
  IPv4-mapped, and IPv6-ULA addresses, with resolve-once IP-pinning for `http`. A 1 MiB streamed body
  cap bounds the response. Residual accepted risk: the https path is subject to an SNI/DNS-rebind TOCTOU
  window.
- **Rate limiting extended to media:** the existing `Nebu.Web.Plugs.RateLimit` (per-IP token bucket) now
  also guards `preview_url` (30/min) and `upload` (600/min).
- **Locality of Behavior (ADR-018):** the media code uses inline SQL with no schema/repository layer;
  boundary seams (DB, storage, HTTP fetch) are injected via `Application.get_env` for testability.

## Matrix Session Lifecycle - Opaque Access Tokens (Story oidc-session-refresh)

> **Stack note (ADR-021):** This concept is now realised in the Elixir/OTP stack. Earlier revisions of
> this section described a Go gateway (`auth.go`, middleware structs, a cleanup goroutine, `GetSSOCallback`).
> Those are superseded — the modules below are the current Elixir implementation. The Go gateway is gone.

**Problem:** Matrix clients connected via OIDC were force-logged-out when the OIDC `id_token` expired
(5 minute default in Keycloak). The login handler previously returned the OIDC JWT directly as the Matrix
`access_token`, tying the Matrix session lifetime to the OIDC provider's short access-token expiry
("force-logout every 5 min" regression).

**Solution:** Nebu now manages Matrix sessions server-side using opaque access tokens + refresh tokens
(Matrix Client-Server API v1.3), decoupled from OIDC token lifetime. The session lifetime is bounded at
`min(oidc_exp, now + 8h)`.

**Dual session model (backward compatible):** `POST /login` issues opaque tokens **only when the client
sends `refresh_token: true`** in the request body; otherwise the raw OIDC JWT is still returned as
`access_token` (the original stateless behaviour). Both token shapes are accepted on subsequent requests —
dispatch is by the *absence of a dot* (opaque tokens are 64-hex; JWTs always contain two dots).

**Architecture:** `Nebu.Matrix.Session.MatrixSessionStore` (inline SQL over the `matrix_sessions` table,
ADR-018 — no Ecto schema/repository) maintains a `matrix_sessions` row with:

```
access_token (PK)  ← Opaque hex string (32 bytes = 64 hex chars, no dots)
refresh_token      ← Opaque hex string (32 bytes), UNIQUE, rotated on each refresh
oidc_refresh_token ← AES-256-GCM encrypted OIDC RT from Keycloak (via Nebu.Web.SecretBox; optional, for future OIDC refresh)
user_id            ← Matrix user ID (@user:server.name)
device_id          ← From JWT "did" claim or SSO device registration
expires_at         ← Absolute wall-clock time (Nebu controls expiry: NOW() + 8 hours)
revoked_at         ← Set on logout or session invalidation (immediate, no grace)
grace_until        ← Grace window end time for old refresh token after rotation (NOW() + 60s)
created_at         ← Session creation timestamp
```

**Token validation:** `Nebu.Web.Plugs.OidcPlug` dispatches by token shape — an opaque token is any
bearer value with no `.` (JWTs always contain two dots). The JWT path is unchanged.

When the bearer token is opaque:
1. Look up the row via `MatrixSessionStore` by `access_token`
2. If not found: `401 M_UNKNOWN_TOKEN "Invalid token"`
3. If found but `revoked_at IS NOT NULL`: `401 M_UNKNOWN_TOKEN "Token has been logged out"`
4. If found but expired (re-check `is_active` / `expires_at < NOW()`): `401 M_UNKNOWN_TOKEN` with
   `soft_logout: true` so the client can silently re-auth without dropping the device
5. If found and valid: populate `conn.assigns` (user_id, device_id) from the session row

When the bearer token contains a dot, routing continues on the existing OIDC JWT path (backward compat).

**Device assigned on EVERY authenticated request (Story s2-device-lifecycle-at-login):**
`OidcPlug` now populates `conn.assigns[:device_id]` for **both** session shapes — opaque sessions
read it from `matrix_sessions.device_id`, raw-JWT sessions read it from
`Nebu.Matrix.Session.DeviceBinding.get_device/1` (the `jwt_device_bindings` row keyed by
`SHA-256(token)`). This closes the prior gap where raw-JWT sessions had no server-side device. The
device a request acts as is therefore **server-authoritative** for all sessions (see *Device Identity
vs Device Keys* below).

**Session creation (`POST /login`):**

When the client sends `refresh_token: true`:
1. Validate the OIDC token in-process (existing login logic)
2. If an OIDC refresh token is available, encrypt it with `Nebu.Web.SecretBox` (AES-256-GCM) before
   storing it in `oidc_refresh_token`
3. Generate opaque `access_token` and `refresh_token` (32 random bytes each → 64-hex)
4. Compute `expires_at = min(oidc_exp, NOW() + 8h)` — decouples the Matrix session from Keycloak's short
   access-token lifetime
5. Insert the `matrix_sessions` row and return `{access_token, refresh_token, expires_in_ms, …}`

When the client omits `refresh_token: true`, the raw OIDC JWT is returned as `access_token` and no
session row is written (original stateless behaviour).

**Session refresh (`POST /_matrix/client/v3/refresh`):**

Registered OUTSIDE the auth pipeline (unauthenticated by spec) but **rate-limited** via the per-IP
`Nebu.Web.Plugs.RateLimit` token bucket:

1. Extract `refresh_token` from the request body
2. Look up the session by `refresh_token` (including grace-window state)
3. If not found or the grace window has expired: `401 M_UNKNOWN_TOKEN` with `soft_logout: true`
4. Generate a new opaque `access_token` + `refresh_token`
5. Compute `expires_at = min(oidc_exp, NOW() + 8h)`
6. Rotate atomically: write the new tokens and mark the old row `revoked_at = NOW()`,
   `grace_until = NOW() + 60s`
7. Return `200 {"access_token", "refresh_token", "expires_in_ms"}`

**Grace period semantics (Spec MUST):**

The 60-second grace window lets a client that failed to persist the `/refresh` response retry with the
same old refresh token without error. After the window the old refresh token returns `401 M_UNKNOWN_TOKEN`.

**Logout:** `POST /logout` deletes the user's `matrix_sessions` rows (immediate, no grace window).

**Admin deactivation:** `deactivate_user` also deletes the target user's `matrix_sessions` rows, so an
admin-deactivated user's opaque sessions are invalidated immediately.

**Comparison to Admin Sessions:**

| Aspect | Admin Sessions | Matrix Sessions |
|---|---|---|
| Storage | Signed Phoenix session cookie (no DB row) | `matrix_sessions` table |
| Token format | Encrypted claims/RT in the signed cookie | Opaque hex (64-hex, no dots) |
| Encrypted OIDC RT | Yes — AES-256-GCM (`Nebu.Web.SecretBox`) in the cookie; used for active refresh | Yes (future: allows Keycloak session binding) |
| Lifetime control | `session_exp = min(id_token.exp, now + 8h)` | `min(oidc_exp, now + 8h)` for all Matrix clients |
| Refresh pattern | When `admin_oidc_refresh_mode = offline`: silent OIDC RT exchange on HTTP requests within a 120 s pre-expiry window, admin-group gate re-evaluated each refresh. Default `online` → no `offline_access`, no silent refresh (see refresh-mode config below) | On-demand via `/refresh` endpoint; `matrix_oidc_refresh_mode` (default `offline`) controls whether `offline_access` is requested |
| Grace period | None (refresh failure / lost group → clear session, redirect `/admin/login`) | 60s grace after token rotation (AC4) |

## Cryptography

**Two key pairs per user (ADR-007):**

| Key Pair | Algorithm | Purpose |
|---|---|---|
| Signing Key | Ed25519 | Message signatures, non-repudiation |
| Encryption Key | X25519 (ECDH) | PII encryption, GDPR deletion |

Generated at user registration via Erlang/OTP 27 `:crypto` - no external Hex packages.

**Event signing:** All Matrix events are signed with the sender's Ed25519 private key before storage.
`Nebu.EventId.generate/1` computes `$<base64url(SHA-256(canonical_json(event)))>`.

**GDPR Right-to-be-Forgotten:** Delete both private keys → sensitive PII (email, IdP subject) is
permanently irrecoverable. Audit log integrity is preserved - message signatures remain verifiable
via the permanent public key.

**Compliance key:** A separate Ed25519 keypair in `server_config` (AES-256-GCM encrypted) signs
compliance export tokens. Survives Elixir restarts (unlike the ephemeral `:nebu_signing_key`).

## Audit Logging

All administrative actions and compliance access events are written to an append-only `audit_log`
table. Entries are Ed25519-signed for tamper evidence. Retention is configurable (default: 2555 days / 7 years).

`Nebu.Compliance.AuditWriter` validates every `action` against a `@known_actions` allowlist and rejects
an unregistered action with `{:error, :audit_unknown_action}` *before* any DB call — so a new audited
operation MUST add its action there or its entries are silently dropped. The Admin device-management
operations (Story s4) registered `device_renamed` and `device_deleted` accordingly.

**Append-only enforcement model (Story 13-14):**

The `audit_log` table uses `ENABLE ROW LEVEL SECURITY` with two blocking policies - `audit_log_no_update USING (false)` and `audit_log_no_delete USING (false)`. `FORCE ROW LEVEL SECURITY` is intentionally **not** set in the squashed single-role migration.

| Deployment model | Mechanism | Rationale |
|---|---|---|
| Single-role (`nebu_app` = table owner) | Application-layer enforcement + RLS policies block non-owner sessions; `nebu_app` as table owner bypasses RLS naturally (no FORCE RLS). `audit_log_purge()` SECURITY DEFINER works without `BYPASSRLS`. | `FORCE RLS` would require `BYPASSRLS` on `nebu_app` for `audit_log_purge()` to succeed - this privilege escalation is avoided by design. |
| Dual-role (`nebu_migrate` = function owner with BYPASSRLS) | FORCE RLS + SECURITY DEFINER escalation - supported by legacy incremental deployments. | Dual-role BYPASSRLS privilege on the migration role is not exposed in the squashed migration. |

**Immutability guarantee in single-role mode:** The `nebu_app` application role is the table owner. Direct DELETE/UPDATE on `audit_log` issued deliberately by the application owner will succeed - the RLS policies block only non-owner roles. Defence-in-depth is provided by `REVOKE UPDATE, DELETE ON audit_log FROM nebu_app` (no-op for owner, meaningful for non-owner sessions in dual-role deployments) and by application-layer invariants: the gateway never issues `DELETE` or `UPDATE` on `audit_log` outside of `audit_log_purge()`.

**`audit_log_purge(retention_days INT)`** is a `SECURITY DEFINER` function that deletes rows older than `retention_days` (bounds: 1–36500). `EXECUTE` is restricted to `nebu_app`; `PUBLIC` access is revoked. The `BEFORE INSERT` trigger `audit_log_event_time_force_trigger` forces `event_time = NOW()` on every insert, preventing backdating.

**Failure audit trail pattern (Story 9-27):** Multi-step operations (e.g. room upgrade) that can
fail partway through wrap their entire body in `try/rescue`. The `rescue` clause writes a "failure"
audit entry (including an `"error"` metadata field with the exception message) before reraising the
original exception. A nested `try/rescue` around the audit write itself ensures an outage in the
audit writer never masks the original error. This guarantees that any partially-applied operation
leaves a forensic record even when the in-process call ultimately returns an error to the client.

## GDPR Article 17 Right to Erasure - Deletion Orchestration (Story 14.4)

`DELETE /api/v1/admin/users/{userId}` - instance_admin only (four-eyes: caller ≠ target).

The GDPR deletion handler in `Nebu.Compliance.*` chains the existing building blocks into a single atomic-from-the-caller's-perspective pipeline (all steps are in-process calls within the one application):

1. **DeactivateUser** - `is_active=false` + all sessions destroyed (NOT_FOUND → 404 stops pipeline; AlreadyExists → idempotent continue)
2. **DeleteUserKeys** - `private_key = NULL` for signing + encryption keys (best-effort: failure logged, pipeline continues)
3. **DB anonymization TX** - `profiles.displayname = 'Deleted User'`, `profiles.avatar_url = NULL`, `users.anonymized_at = <unix_ms>` (failure → 500, PII erasure MUST NOT be silently skipped)
4. **Audit emit** - `gdpr_deletion` event with `keys_deleted: "confirmed"|"failed_best_effort"` metadata (never-raise: audit failure does not block 200)
5. **200** `{"user_id": "...", "status": "gdpr_deleted"}`

**Login behavior after deletion:** `POST /_matrix/client/v3/login` - when token validation finds the user `"deactivated"`, the login handler responds `403 M_USER_DEACTIVATED` (Matrix CS API v1.18 compliant).

**Room history preservation:** Messages in room event timelines are NOT deleted - per Matrix spec and GDPR recital 65 (legitimate archive interest). The sender's profile is anonymized; message content remains.

Runbook: `docs/compliance/gdpr-deletion-runbook.md`

## Three PII Tiers

| Tier | Data | At Rest | GDPR Deletion |
|---|---|---|---|
| Operational PII | Display name, avatar | Encrypted at rest | Overwrite with "Deleted User" (via `GdprDeleteHandler`, Story 14.4) |
| Sensitive PII | Email, IdP subject | Encrypted with user's X25519 key | Delete private key → irrecoverable (via `DeleteUserKeys`, Story 5.7) |
| Message Content | Chat messages | Plain in DB (audit requirement) | Not deleted; sender anonymized |

## Per-Device Sync Token Isolation (Story 9-22)

Matrix clients identify themselves with a `device_id` extracted from the `"did"` claim in the
JWT access token. The Elixir Server maintains independent sync checkpoints per `(user_id, device_id)`
in the `sync_tokens` table (composite PK, migration 000041).

**Design invariants:**

- A single user with N active devices has N independent rows in `sync_tokens`.
- Each device's `since` token is advanced only by that device's sync responses.
- On logout, only the `(user_id, device_id)` row is removed; other devices are unaffected.
- Legacy clients (no `device_id` in JWT) fall back to the `device_id = ''` row; a token mismatch
  triggers a full initial sync (safe degradation).
- `persist_since_token/4` and `get_since_token/2` are the device-aware arities in
  `Nebu.Session.PgStore.Postgres`; `/3` and `/1` remain for backward compatibility.

**Token cleanup on logout:**
`POST /logout` invalidates the session in-process via `SessionSupervisor.destroy_session/2` (a
DB transaction that deletes the `sync_tokens` + `sessions` rows for that device). ETS is NOT evicted
(other devices may still be active).

## Device Identity vs Device Keys (Story s1-device-registry-model)

A **device** is a first-class entity, modelled separately from the cryptographic key blob a client
may publish. Two tables back this split, both keyed on `(user_id, device_id)`:

| Table | Migration | Holds | A row exists when |
|---|---|---|---|
| `devices` | 000010 | Device IDENTITY + management metadata (`display_name`, `last_seen_ts`, `last_seen_ip`, `created_at`, `updated_at`) | The device is known to the server — even with no published keys (*keyless* device) |
| `device_keys` | 000009 | The signed device-key blob (`device_keys_json`) + OTK/fallback keys (in sibling tables) | The client uploaded keys via `POST /keys/upload` |

**Design invariants:**

- **Device existence is independent of keys.** `Nebu.Matrix.DeviceKeyStore.put_device_keys/4` upserts
  the `devices` row FIRST, then the `device_keys` row (the two writes are deliberately NOT in a
  transaction: writing `devices` first means the only intermediate state after a crash between them is
  a valid keyless device, which is permitted; the reverse order could leave a `device_keys` row with no
  `devices` row).
- **`GET /devices` / `GET /devices/{deviceId}` read from `devices`** (`list_devices/1`, `get_device/2`,
  `sole_device_id/1`), so a keyless device is listed and manageable.
- **`POST /keys/query` reads the JOIN** (`query_devices/1` INNER-JOINs `devices` + `device_keys`), so it
  returns ONLY key-bearing devices — Matrix `/keys/query` semantics are unchanged. The JOIN can never
  hide a current key-bearing device because every `device_keys` row is guaranteed a `devices` row (the
  000010 backfill + the put-order invariant above).
- **Backfill of a shipped schema.** Migration 000009 reached the operator's Stackit deployment and is
  immutable; 000010 is a NEW forward migration that backfills `devices` from existing `device_keys` rows
  (`last_seen_ip` has no source there → NULL) and is idempotent (`IF NOT EXISTS` / `ON CONFLICT DO
  NOTHING`).

This split is the foundation of the device-management epic (S2 session-driven device existence, S3, S4).
It is **orthogonal to E2EE** (ADR-011): persisting device identity encrypts nothing. PostgreSQL-backed
and cluster-correct (ADR-020); inline SQL with no schema/repository layer (ADR-018). No new ADR.

### Login owns the device lifecycle; the acting device is server-authoritative (Story s2-device-lifecycle-at-login)

S2 makes **login** the single owner of device creation and makes the **acting device
server-authoritative** on every authenticated request:

- **Login owns device creation.** `Nebu.Matrix.HttpPublic` honours a client-supplied `device_id`
  (reuse — Matrix permits it) or generates one, then upserts the `devices` row (`display_name` taken
  from `initial_device_display_name` on first sight only; `last_seen` refreshed on every login). For a
  raw-JWT session it additionally persists the `token→device` binding via
  `Nebu.Matrix.Session.DeviceBinding` (opaque sessions already carry the device in
  `matrix_sessions.device_id`). The binding write is best-effort and never crashes login.
- **The acting device is read from the token, never the request body.** `OidcPlug` assigns
  `conn.assigns[:device_id]` for ALL authenticated sessions from the token's server-side binding
  (opaque → `matrix_sessions`, raw-JWT → `DeviceBinding`). Handlers read the device from there.
- **`POST /keys/upload` rejects cross-device transfer.** The device a key write is attributed to is
  taken SOLELY from `conn.assigns[:device_id]`. A body `device_keys.device_id` that *contradicts* the
  bound device is rejected with `403 M_FORBIDDEN` **before any write** — a token bound to device A can
  never publish keys for device B (the prior `sole_device_id/1` heuristic is removed). With no bound
  device and no body device_id the upload is a no-op (empty counts, no DB touch).
- **`GET /sync`** performs a best-effort, throttled (60s) update of `devices.last_seen_ts` /
  `last_seen_ip`.

**Security property:** the device a request acts as is **server-authoritative** — derived from the
token's server-side binding, never from attacker-controllable request input — which prevents
cross-device session/token transfer. The binding stores the access token only as a **SHA-256 hash**
(no cleartext bearer token at rest). Cluster-correct (PostgreSQL is the source of truth, per ADR-020);
inline SQL (ADR-018). Still **orthogonal to E2EE** (ADR-011) — the device-key directory is a public-key
directory, not encryption. No new ADR.

### Device management endpoints, UIA step-up, and the per-device JWT kill-switch (Story s3-matrix-device-endpoints)

S3 adds the WRITE side of Matrix device management — `PUT /_matrix/client/v3/devices/{deviceId}`
(rename), `DELETE /_matrix/client/v3/devices/{deviceId}`, and `POST /_matrix/client/v3/delete_devices`
(bulk, capped at ≤100 target devices) — all owner-scoped (a user can only touch their own devices).
Delete and bulk-delete are gated by **User-Interactive Authentication (UIA)**; rename is not.

**UIA fresh-auth step-up via `m.login.sso` (Option B).** Nebu is OIDC-only, so the single UIA stage is
`m.login.sso` (CS API §"SSO during User-Interactive Authentication"). The gate is **Option B**: a recent
fresh login satisfies UIA directly. `Nebu.Matrix.Uia` compares `now - matrix_sessions.auth_time` against
a configurable window (`NEBU_UIA_FRESH_AUTH_SECONDS`, default **900s / 15 min**); within the window the
write proceeds, otherwise the caller is challenged (`401` with a `m.login.sso` flow + a server-issued
`session` id). The challenged client completes a fresh SSO login out-of-band via
`GET /_matrix/client/v3/auth/m.login.sso/fallback/web` (unauthenticated by spec) and re-submits.

- **`auth_time` tracking.** Set at login from the id_token's `auth_time`/`iat` (unix seconds, migration
  `000012`). A **token refresh copies it verbatim** (`MatrixSessionStore.refresh_auth_time/2` is only
  called on a fresh SSO completion, never on rotation), so refreshing a token can NOT reset freshness or
  defeat the gate. A session with no `auth_time` is always stale → challenge.
- **UIA session store (DB-backed, ADR-020).** A `uia_sessions` row is server-issued (256-bit random
  `session_id`) and bound to `(user_id, op, params)` (params = the canonical-JSON sorted device-id list).
  It is **single-use**: `consume/4` flips `consumed = TRUE WHERE consumed = FALSE` atomically, so a replay
  loses the race and is rejected. The store is in PostgreSQL — not node-local ETS — because mint
  (challenged request) → complete (SSO callback) → consume (re-submit) can each land on a different node.
- **Identity-bound completion (security, H-1).** `Uia.complete/2` marks the `m.login.sso` stage complete
  ONLY when the freshly-verified `sub` (the Matrix user derived from the verified id_token) equals the UIA
  session's bound `user_id` — enforced in SQL by `AND user_id = $authenticated_user`. Without this, a
  holder of a victim's open access token could complete the fallback with their OWN IdP account and
  satisfy the step-up for the victim's pending sensitive op. A mismatch matches 0 rows and returns
  `:error` (no stage completion, no `auth_time` refresh).

**Per-device JWT kill-switch (F-1).** Deleting a device (single or bulk) **denylists every JWT bound to
that `(user_id, device_id)`** so an in-flight bearer token cannot outlive the device. The handler
enumerates `jwt_device_bindings` rows for the pair (served by `idx_jwt_device_bindings_user_device`) and
calls `Nebu.Web.TokenDenylist.revoke_by_hash/2` for each, keyed by the binding's `token_hash` until that
token's stored `exp`. The hash is **the same `SHA-256(token)` lowercase-hex digest** `OidcPlug.revoked?/2`
computes from an incoming token and that `DeviceBinding` stores — so the next request carrying the bound
JWT resolves as revoked and is rejected `401 M_UNKNOWN_TOKEN`. Bindings for the deleted device are then
removed. The companion `Nebu.Matrix.Session.Sweeper` (hourly, supervised) evicts `jwt_device_bindings`
rows whose `exp` has passed and expired `uia_sessions` rows.

**`device_id` ingress validation (F-2).** `Nebu.Matrix.DeviceId.valid?/1` rejects a client-supplied
`device_id` longer than 255 bytes or containing control characters (`\x00`–`\x1f`, `\x7f`) at the two
ingress points that accept one — `POST /login` and `POST /keys/upload` — so a device_id can never inject
log/header/path artifacts downstream.

All inline SQL (ADR-018), cluster-correct (ADR-020). **Orthogonal to E2EE (ADR-011):** none of these
endpoints store key material or can enable encryption — they manage device identity and session
lifecycle only. No new ADR.

### Admin UI per-user device management (Story s4-admin-device-management)

S4 gives operators the same device-management capabilities over **another user's** devices, from the
Admin UI (Phoenix dead-view / HTTP controller, not the Matrix CS API). A user-detail page
(`GET /admin/users/:user_id`) lists every device (semantic table: device id, display name, last-seen,
created), with a rename form and a revoke form (native confirm) per row. All three routes are
`:require_admin`-gated, CSRF-protected, and follow the PRG (Post/Redirect/Get) pattern; revoke uses
`POST .../devices/:device_id` with `_method=DELETE` (`Plug.MethodOverride`), mirroring the rooms
member-removal destructive-action pattern.

- **The Admin domain consumes devices ONLY through the `Nebu.Matrix` facade (ADR-020)** —
  `list_user_devices/1`, `rename_user_device/3`, `delete_user_device/2` — never `DeviceKeyStore` or
  `Session.*` directly (see §05 building blocks for the facade contract).
- **Revoke reuses the S3 kill-switch.** `delete_user_device/2` runs the per-device JWT kill-switch
  FIRST (denylist every token bound to `(user_id, device_id)` until its own `exp` via
  `TokenDenylist.revoke_by_hash/2`, drop the bindings + the opaque session), THEN deletes the device
  identity row and all key material. Because an admin acts on *another* user's device there is no
  caller credential to preserve — EVERY bound token is revoked (unlike the Matrix self-delete path).
- **No IDOR.** Rename and delete are user-scoped in SQL; a `device_id` that does not belong to the
  path `:user_id` maps to `:error`/no-op and a flash — never to another user's device.

**Audit on success AND failure.** Each successful rename/revoke writes a `device_renamed` /
`device_deleted` audit entry (actor = admin, target user + device); a failed attempt is also audited.
Both actions are registered in `Nebu.Compliance.AuditWriter`'s `@known_actions` allowlist — an
unregistered action is rejected with `{:error, :audit_unknown_action}` *before* any DB call, so a
missing registration would silently drop the entry (see *Audit Logging* below). The `do_log` rescue is
narrowed to `RuntimeError` (the documented missing-`Repo` degradation) so genuine logic bugs in the
audit path still crash rather than being swallowed.

No new migration (S4 reuses the S1–S3 schema), inline SQL (ADR-018), cluster-correct (ADR-020),
orthogonal to E2EE (ADR-011). No new ADR.

## Error Handling

**Elixir:** Tagged tuples `{:ok, result}` / `{:error, reason}`. No raise/throw for business logic.
Let-it-crash + OTP Supervisor Trees for unexpected failures. The HTTP layer maps domain results to
Matrix error envelopes (`{"errcode": "M_...", "error": "..."}`). The in-process command layer
(`Nebu.Matrix.EventDispatcher.Server`) raises `Nebu.Matrix.Error` with a `Nebu.Matrix.Status`
atom as its error type (e.g. `:not_found`, `:permission_denied`, `:internal`);
`Nebu.Matrix.Http.call_core/1` translates the status atom to the HTTP/Matrix response.
(Prior to the `grpc-removal` epic, these were `GRPC.RPCError` / `GRPC.Status.<code>()` — that
dependency is fully removed, ADR-021 2026-06-22.)

**Media Gateway - Storage Error Classification (Story 12.4):**

The `Storer` interface returns sentinel errors that map to specific HTTP status codes:

| Sentinel | Cause | HTTP | errcode |
|---|---|---|---|
| `storage.ErrNotFound` | Object absent from backend (MinIO `NoSuchKey`, OS `ErrNotExist`) | 404 | `M_NOT_FOUND` |
| `storage.ErrStorageUnavailable` | Network unreachable, MinIO degraded, other MinIO errors | 502 | `M_UNKNOWN` |
| other | Crypto failure, hex decode error | 500 | `M_UNKNOWN` |

Classification logic: `ClassifyMinIOError` uses `errors.As` to unwrap `minio.ErrorResponse` (not `minio.ToErrorResponse` which does direct type assertion). `LocalStorer.Get` maps `os.ErrNotExist` → `ErrNotFound`. The handler logs the full error via `slog.Error` but returns only a generic message to the client (no credential/endpoint leak).

**Media Gateway - Thumbnail Generation (Story 12.5):**

On-demand thumbnail generation for `GET /_matrix/media/v3/thumbnail/{serverName}/{mediaId}`:

| Concern | Decision | Rationale |
|---|---|---|
| Library | `github.com/disintegration/imaging v1.6.2` (MIT) | Pure Go, no cgo, no shell exec - sandboxed by construction |
| MIME detection | `net/http.DetectContentType` on first 512 bytes | Magic bytes only; never trust stored `Content-Type` |
| Allowed types | `image/jpeg`, `image/png`, `image/gif`, `image/webp` | Deny-by-default: SVG/PDF/PS/EPS → 400 M_BAD_JSON |
| Scale method | `imaging.Fit` | Aspect-ratio-preserved, fits within W×H |
| Crop method | `imaging.Fill` (center) | Center-crop to exactly W×H |
| Animated GIF | `gif.DecodeAll` + per-frame resize + Floyd-Steinberg re-palettize | Preserves all frames + loop count |
| animated=false | Static JPEG (first-frame decode) | Spec MUST NOT return animated thumbnail |
| Output format | JPEG (85 quality) for static; GIF for animated | Balance size/quality |
| Headers | `Content-Disposition: inline; filename=...` (spec v1.12) + `Cache-Control: max-age=86400` | Matrix spec MUST requirements |
| Security | `mediaId` validated with `^[A-Za-z0-9_\-]+$` before DB/storage call | Path traversal prevention (Matrix spec §5.6) |
| Dimension cap | `const maxThumbDim = 2048`; width > 2048 or height > 2048 → 400 M_BAD_JSON | Memory-amplification DoS prevention (Story 12.7 HIGH-1) |
| Source image budget | After `imaging.Decode`, check `Dx * Dy > 100_000_000` → return error | Decompression-bomb defence - prevents ≥400 MB allocations from compressed source |
| GIF frame cap | `len(g.Image) > maxGIFFrames (200)` → truncate to first 200 frames silently | Bounded resource usage for animated GIFs; no error returned |
| Response headers | `X-Content-Type-Options: nosniff` set on all thumbnail responses | Prevent MIME sniffing in legacy browsers (Matrix spec v1.12) |

**Media Gateway - Upload/Download Security (Story 12.7 HIGH-3):**

Content-Type enforcement to prevent stored XSS:

| Phase | Rule | Mechanism |
|---|---|---|
| Upload - blocklist | `text/html`, `application/xhtml+xml`, `text/javascript`, `application/javascript`, `image/svg+xml`, `application/x-shockwave-flash` → 400 M_BAD_JSON | `blockedContentTypes` map; normalized with `mime.ParseMediaType` (strips params) |
| Download - safe inline | `image/jpeg`, `image/png`, `image/gif`, `image/webp`, `image/avif`, `audio/mpeg`, `audio/ogg`, `video/mp4`, `video/webm`, `application/pdf`, `text/plain` → `Content-Disposition: inline` | `safeInlineContentTypes` map; normalize with `strings.SplitN(...,";",2)` |
| Download - unsafe fallback | All other stored types → `Content-Type: application/octet-stream`, `Content-Disposition: attachment` | Prevents inline rendering of pre-allowlist uploads |
| All download responses | `X-Content-Type-Options: nosniff` always set | Prevent MIME sniffing |

**Media Gateway - Upload JWT Validation + Fail-Closed OIDC Startup (Stories 12.7, 12.8):**

The upload handler uses a `TokenVerifier` interface (`HandlerConfig.OIDCVerifier`). `OIDCTokenVerifier` wraps `*oidc.IDTokenVerifier` and implements `VerifyToken(ctx, rawToken) (string, error)` - returning the uploader's subject identity from the operator-configured OIDC claim (see Story 12.11 below). Uploads with a nil verifier receive `503 M_UNAVAILABLE` (fail-closed, not fail-open).

**Startup hardening (Story 12.8 + Story 12.12 F-3):** `NEBU_OIDC_ISSUER` is mandatory. If empty, the media gateway exits immediately with `FATAL: NEBU_OIDC_ISSUER is required`. If Dex is unreachable at startup, `initOIDCVerifier` retries up to 5 times with 2s backoff, then exits (`FATAL: media: OIDC provider unreachable after retries`). The service never starts with a nil verifier. This eliminates the "OIDC fail-open at startup" pattern documented as a recurring vulnerability.

Story 12.12 (F-3) adds a **10-second per-attempt timeout** to each `oidc.NewProvider` call via `context.WithTimeout(ctx, 10s)`. A provider that accepts the TCP connection but never sends a response (hung Dex, firewall issue) can no longer block startup indefinitely - each attempt fails within 10s, and the 5-retry cycle completes within ≤60s total. Parent context cancellation (SIGTERM during startup) is checked at the top of every retry iteration for immediate exit.

Story 12.13 completes **graceful shutdown during OIDC retries**: `main()` creates a SIGTERM-aware context via `signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)`. This makes the parent `ctx` actually cancel on SIGTERM - previously `context.Background()` was used and the ctx.Err() guard was dead code for signal handling. Additionally, the inter-retry sleep (`time.Sleep(retryDelay)`) is replaced by a ctx-aware `select { case <-time.After(retryDelay): case <-ctx.Done(): return error }`. A SIGTERM received during the 2-second backoff sleep now interrupts immediately rather than waiting up to 2s, ensuring `docker compose stop` completes within Docker's 10-second grace window. Log messages distinguish signal abort (`slog.Info`) from retry exhaustion (`slog.Error`).

**Story 12.14 - Full runtime graceful shutdown (HTTP + DB Pool + Rate Limiter):** Completes the SIGTERM story. Three runtime gaps are closed:

1. **HTTP drain** - `srv.ListenAndServe()` runs in a background goroutine. `main()` blocks on `select { case err := <-serverErr; case <-ctx.Done() }`. On SIGTERM, `srv.Shutdown(shutdownCtx)` is called with a 30-second timeout. In-flight HTTP requests complete before the server stops accepting new connections. After 30s, `Shutdown` returns `context.DeadlineExceeded` and shutdown proceeds regardless.

2. **DB pool close** - `pool.Close()` is called explicitly after `srv.Shutdown` returns (not via `defer`). The `defer pool.Close()` pattern was removed because `os.Exit(1)` bypasses defers; explicit sequencing ensures DB connections are always released. The shutdown order is: `srv.Shutdown` → `pool.Close()` → `slog.Info("media gateway stopped")` → `main()` returns (exit code 0).

3. **Rate limiter goroutine** - `NewIPRateLimiter` now accepts `ctx context.Context` (see Rate Limiting section above). The cleanup goroutine exits cleanly when SIGTERM cancels the context.

Shutdown helper: `runShutdownSequence(ctx context.Context, srv *http.Server, poolClose func())` encapsulates the ordered shutdown steps and is unit-testable with a spy closure for `poolClose` (no real DB pool required in tests).

**Media Gateway - Authenticated Media Endpoints (Story 12.16):**

Matrix CS API v1.11+ introduced authenticated download/thumbnail paths (`/_matrix/client/v1/media/*`) alongside the deprecated unauthenticated `/_matrix/media/v3/*` paths. The Media Gateway now implements both path families.

**Auth middleware package (`media/internal/auth`):**

The `auth.Middleware` wraps any `http.Handler` with Bearer token verification. It defines a local `TokenVerifier` interface (same signature as `upload.TokenVerifier` - no import cycle):

```go
type TokenVerifier interface {
    VerifyToken(ctx context.Context, rawToken string) (string, error)
}
```

Error mapping:

| Condition | HTTP | errcode |
|---|---|---|
| Missing or non-Bearer Authorization header | 401 | `M_MISSING_TOKEN` |
| Empty Bearer token (`Bearer ` with nothing after) | 401 | `M_MISSING_TOKEN` |
| Verifier returns error (invalid/expired token) | 401 | `M_UNKNOWN_TOKEN` |
| Nil verifier (guard) | 503 | `M_UNAVAILABLE` (fail-closed) |
| Valid token | - | handler called |

`*upload.OIDCTokenVerifier` satisfies `auth.TokenVerifier` structurally; the same instance (`uploadVerifier` from `initOIDCVerifier`) is reused - no separate OIDC client or audience check.

**Routing pattern in `main.go`:**

```
// Deprecated unauthenticated (backward compat):
GET /_matrix/media/v3/config          → configHandler (no auth)
GET /_matrix/media/v3/download/...    → downloadHandler (no auth)
GET /_matrix/media/v3/thumbnail/...   → thumbnailHandler (no auth)

// v1.11+ authenticated:
GET /_matrix/client/v1/media/config                          → authMW.Wrap(configHandler)
GET /_matrix/client/v1/media/download/{serverName}/{mediaId} → authMW.Wrap(downloadHandler)
GET /_matrix/client/v1/media/download/{serverName}/{mediaId}/{fileName} → authMW.Wrap(downloadHandler)
GET /_matrix/client/v1/media/thumbnail/{serverName}/{mediaId} → authMW.Wrap(thumbnailHandler)
```

The `{fileName}` path segment maps to `r.PathValue("fileName")` inside the download handler for the `Content-Disposition` filename. When the route without `{fileName}` is matched, `PathValue` returns `""` and the handler falls back to `mediaId`.

**Security response headers on download and thumbnail (Matrix spec §Media Repository SHOULD, v1.4+):**

All 200 responses from the download and thumbnail handlers - on both v3 and v1 paths - now include:

```
Content-Security-Policy: sandbox; default-src 'none'; script-src 'none'; plugin-types application/pdf; style-src 'unsafe-inline'; object-src 'self';
Cross-Origin-Resource-Policy: cross-origin
```

These headers prevent script execution from served media objects and allow cross-origin image loading by Element Web (required for inline image display in rooms).

**Canonical Matrix user ID in audit trail (Story 12.9):** After OIDC verification, the upload handler constructs a canonical Matrix user ID before storing `uploader_user_id` in `media_files`:

```
uploader_user_id = formatMatrixUserID(subject, serverName)
                 = "@" + sanitiseLocalpart(subject) + ":" + serverName
```

localpart sanitisation keeps only `[a-z0-9._-]` characters (spaces → `_`, all others dropped) — the same rule used for Matrix user IDs throughout the app. `NEBU_SERVER_NAME` is mandatory (the app raises at boot if unset). Historical rows (pre-12.9) contain raw OIDC claims and are grandfathered; see migration 000047 column comment. This enables compliance officers to correlate `media_files.uploader_user_id` with room event `sender` fields without manual claim-mapping.

**Configurable OIDC claim for audit trail (Story 12.11 SEC Fix F-1):** The claim used as the audit trail user identity is now operator-configurable via `NEBU_OIDC_USER_ID_CLAIM` (default: `name`, matching migration 000044 column comment and the gateway's DB default).

| `NEBU_OIDC_USER_ID_CLAIM` | Behavior |
|---|---|
| unset or `name` (default) | Uses the `name` claim from the OIDC token |
| `sub` | Uses the `sub` claim (UUID from IdP) |
| `email`, `preferred_username`, etc. | Uses the specified claim |
| any (configured claim missing) | Falls back to `sub` with a `slog.Warn` log entry |

Implementation: `extractClaimFromMap(rawClaims map[string]interface{}, claimName string) (string, error)` - pure function in `media/internal/upload/upload.go`. The value goes through `sanitiseLocalpart` before storage. `OIDCTokenVerifier` is constructed with `NewOIDCTokenVerifier(idTokenVerifier, claimName)` in `initOIDCVerifierWith`.

**server_config RLS UPDATE Policy (Story 12.7 MEDIUM-5, extended Story 14-2a):**

Migration 000046 replaces the blanket `config_update_all` policy (USING true - introduced in migration 000045 for OIDC claim upserts) with a key-scoped `config_update_mutable` policy. Migration 000048 (Story 14-2a) extends the allowlist with two new OIDC directory keys. Migration 000049 (Story 14-3c) extends with three SCIM 2.0 keys. Only the following keys are updatable by `nebu_app`:

- `oidc_user_id_claim`, `oidc_displayname_claim`, `oidc_email_claim`, `admin_group_claim`
- `oidc_issuer`, `oidc_client_id`, `oidc_client_secret`
- `oidc_directory_enabled`, `oidc_directory_endpoint` _(added in migration 000048, Story 14-2a)_
- `scim_enabled`, `scim_base_url`, `scim_bearer_token` _(added in migration 000049, Story 14-3c; bearer token is AES-256-GCM encrypted - raw value never stored in plaintext)_

`server_name`, `bootstrap_completed`, and any future keys not in this allowlist are immutable at the DB level (defence-in-depth restoration from ADR G8).

**Bool / Direct DB Upsert Pattern (Story 14-2a):**

Fields stored as booleans in `server_config` (e.g. `oidc_directory_enabled`) must be updated
with explicit nil-awareness. The pattern used: the Admin UI handler (in `Nebu.Admin.*`) upserts
directly via inline SQL rather than going through the generic config update path. This avoids
inadvertent resets of boolean flags when only a subset of fields is submitted.

**OIDC Directory Service Pattern (Story 14-2b):**

The OIDC directory service (in `Nebu.Admin.*`) provides a secure, cached client for fetching user lists from an admin-configured OIDC directory endpoint. Key design decisions:

- **secretString type**: the bearer token is wrapped in `type secretString string` with `String() "[REDACTED]"` - prevents accidental log exposure via `%+v` or slog auto-formatting (CR-3).
- **HTTPS-only at call time**: `validateEndpoint` is called inside `FetchUsers` on every invocation, not just at config load. This is a defensive check: if the stored endpoint is later mutated to HTTP, the service fails hard rather than silently falling back (CR-1).
- **No redirect following**: the default `http.Client` uses `CheckRedirect: ErrUseLastResponse`. This prevents an HTTP→HTTPS redirect from bypassing the HTTPS check, and prevents SSRF via provider-issued redirects to internal metadata endpoints (CR-2).
- **Rate limit separation**: `Allow(sessionID string) bool` and `FetchUsers(ctx) ([]OIDCDirectoryUser, error)` are separate methods. Callers MUST call `Allow` before `FetchUsers` to enforce the per-session 5 req/s limit. The separation allows callers to short-circuit before cache or network access. Session IDs MUST come from the validated JWT (admin middleware), not from request headers (CR-5).
- **singleflight + 30s cache**: concurrent cache misses collapse into one outbound call (MR-4). Cache key = SHA-256(endpoint + "|" + token) so rotating the bearer token invalidates the stale cache (MR-1).
- **Graceful degradation**: runtime errors (unreachable host, non-200, JSON parse failure) are logged as warnings and swallowed - FetchUsers returns empty list, not error. Configuration errors (non-HTTPS) are propagated as errors.

**OIDC Directory User Search Merge Pattern (Story 14-2c):**

`Nebu.Admin.UsersLive` (or the REST handler equivalent) merges Nebu DB users (from `list_admin_users` in-process) with OIDC directory users (from `OIDCDirectoryService.FetchUsers`) when `oidc_directory_enabled=true`. Key design decisions:

- **WithOIDCDirectory setter**: `UsersHandler` accepts an `*OIDCDirectoryService` via a fluent setter (`WithOIDCDirectory(svc, serverName)`). The handler field is nil by default - zero-config backward compatibility.
- **Nebu DB wins on dedup**: OIDC users whose `sanitize(sub)` matches a Nebu `UserId` are dropped from the OIDC-only list. The Nebu DB entry always takes precedence.
- **IsOIDCOnly flag**: `UserRowData.IsOIDCOnly=true` + `MatrixIDPreview` mark users present only in the OIDC directory. The preview is computed as `@{sanitize(sub)}:{serverName}` and is not persisted.
- **Non-blocking OIDC failure**: when the OIDC provider is unreachable, `FetchUsers` returns an empty list (logged internally). `ListHandler` detects this via `IsEnabled() && len(oidcUsers)==0` and sets `OIDCWarningBanner` - the Nebu DB list is still rendered.
- **Rate-limit gate**: `Allow(sessionID)` is called before `FetchUsers`. If rate-limited, OIDC fetch is silently skipped (no warning banner - rate-limiting is defensive, not an availability signal).

**Bulk User Provisioning Pattern (Story 14-3a):**

`Nebu.Session.BulkImporter` provisions a list of OIDC users via the `bulk_import_users` in-process call. The provisioning flow is identical to first-login provisioning in `Nebu.Session.TokenValidator.Postgres.provision_new_user`. Key design decisions:

- **Identical to first-login**: `BulkImporter` calls the same `UserStore.upsert_user/2` + `UserProvisioner.provision_user/4` functions as first login. Ed25519 signing keypairs and X25519 encryption keypairs are generated; `display_name` (Tier 1) and `email` (Tier 2) are encrypted identically.
- **Duplicate detection**: a user whose `signing_key_id IS NOT NULL` in the `users` table is counted as `skipped` - not an error. The `UserProvisioner.Postgres` update SQL already uses `WHERE signing_key_id IS NULL` (idempotent guard), but BulkImporter avoids unnecessary keypair generation by checking first.
- **Partial success**: `import_users/1` uses `Enum.reduce` across all users. Exceptions in `import_one/2` are rescued with `try/rescue` - the user is counted as `:failed` and the batch continues. The aggregate `{imported, skipped, failed}` is always returned.
- **No bootstrap path**: bulk import always uses the provided `system_role` (the admin import path always sets "user"). The `BootstrapChecker.upsert_with_bootstrap` step from first-login is skipped (bootstrap is a one-time event that only triggers on the very first login to an empty instance).
- **Trust model**: the bulk-import command handler does not re-validate the admin role itself — the admin-only HTTP access is already enforced by the admin auth gate (`Nebu.Admin.Auth`) before the in-process call reaches it.
- **Module injection**: all three dependencies (`lookup_module`, `user_store_module`, `provisioner_module`) are injectable via `Application.put_env` for test isolation. Default implementations use real PostgreSQL.

**Bootstrap Wizard Step 4 - User Import UI Pattern (Story 14-3b):**

`BootstrapHandler` extends the 3-step wizard with a Step 4 that lets admins pre-provision OIDC users immediately after claim selection. Key design decisions:

- **Redirect chain**: `ClaimSelectionHandler` now redirects to `/admin/bootstrap?step=4` instead of `/admin/dashboard`. Step 4 renders an "Import from OIDC" button. The admin can "Skip and finish" → `/admin/dashboard` at any time.
- **Interface abstraction**: `OIDCDirectoryFetcher` (IsEnabled/FetchUsers) and `BulkImportClient` (BulkImportUsers) behaviours/callbacks allow test injection. `WithImportServices(fetcher, core, serverName)` wires them at startup.
- **Two sub-actions via form POST**: `action=preview` fetches users (SCIM-preferred) and renders the preview table (display name, email, computed Matrix User ID); `action=import` re-fetches + calls `bulk_import_users` in-process + renders imported/skipped/failed counts.
- **AC4 disabled state**: when neither OIDC nor SCIM is enabled, Step 4 renders with a disabled import button.
- **Matrix User ID computation**: reuses `sanitizeOIDCSub(u.Sub)` from `users.go` (same package) to produce `@{localpart}:{serverName}` - identical to the preview shown in the Users page (Story 14-2c).

**SCIM 2.0 User Fetch Pattern (Story 14-3c / ADR-015 Protocol B):**

The SCIM client (in `Nebu.Admin.*`) fetches users from a SCIM 2.0 `/Users` endpoint using RFC 7644 pagination. Key design decisions:

- **Protocol priority**: when both `oidc_directory_enabled` and `scim_enabled` are true, SCIM takes priority over the OIDC directory for the `action=import` (and `action=preview`) flows in Bootstrap Step 4. This is enforced in `BootstrapHandler.StepHandler` via the SCIM-preferred fetcher selection pattern.
- **SCIMFetcher interface**: mirrors `OIDCDirectoryFetcher` (IsEnabled/FetchUsers) so `BootstrapHandler` uses a unified interface for both protocols. `WithSCIMFetcher(f SCIMFetcher)` wires the client at startup.
- **RFC 7644 pagination**: `startIndex` is 1-based; `count=100` per page; iteration terminates on empty `Resources[]`. `totalResults` is used for the early-abort cap check (HR-1).
- **secretString CR-1**: bearer token stored as `secretString` - `.String()` returns `[REDACTED]`; `.value()` only called to set the `Authorization` header.
- **Bearer token encryption at rest**: stored as AES-256-GCM (nonce || ciphertext, hex) in `server_config.scim_bearer_token`. Encrypted at config-save time with the internal secret; decrypted at startup before wiring into `SCIMClient`.
- **scim_base_url convention**: the stored URL is the SCIM service root (e.g. `https://idp.example.com/scim/v2`). `buildPageURL` appends `/Users` if not already present, then adds `startIndex`/`count` query params.
- **userName as sub**: `scimSub()` prefers `userName` over `id` - Azure AD and Okta export email-style userNames that align with OIDC `sub` semantics. The sub value goes through `sanitizeOIDCSub` for Matrix localpart derivation (same path as OIDC directory).
- **Import progress singleton**: `importInProgress atomic.Bool` + `importProgress *importProgressState` are package-level singletons. `CompareAndSwap(false, true)` before each import → HTTP 409 on concurrent attempt (HR-3). Counters (`imported`, `total`, `failed`, `done`) are `atomic.Int32`/`atomic.Bool` - safe to read from the polling endpoint without a lock.
- **Progress endpoint**: `GET /api/v1/admin/bootstrap/import-status` (behind `sessionGuard`) returns `{imported, total, failed, done}` JSON. The Bootstrap Wizard Step 4 HTML polls this endpoint via `setInterval` every 2s using `fetch(credentials: 'same-origin')`.
- **Synchronous import**: for S-size story scope, `bulk_import_users/1` is called synchronously; counters advance from 0/N to imported/N/done in a single step after the call returns. The progress bar shows 0/N while the call is in flight, then reloads the page on `done=true`.

**Media Event Content Pass-Through Contract (Story 12.6):**

`content.info` in `m.room.message` (and all other event types) is an **opaque JSON object** - the send
handler passes it verbatim to the event-dispatch layer, which stores it as JSONB without field
inspection or modification. Client extension fields such as `blurhash` (used by Element Web for image
loading placeholders) MUST be preserved through the full round-trip: send handler → event dispatch →
DB → sync response.

- The server never computes `blurhash` - it is always client-provided.
- The send/sync handlers carry `content` as an opaque JSON value end-to-end - no field filtering.

This contract is validated by the blurhash pass-through tests in the Matrix domain test suite (AC1: send carries the field through; AC2: sync returns it unchanged).

**Error surface rule (Story 9-27):** the in-process command handlers
(`Nebu.Matrix.EventDispatcher.Server`) raise `Nebu.Matrix.Error` with a `Nebu.Matrix.Status` atom
as their error type. Bare `:ok =` pattern matches on `Room.Server` calls produce a `MatchError`,
which maps to an ambiguous HTTP 500 with no structured error message. The correct form is a `case`
expression that raises with `Nebu.Matrix.Status.internal()` on unexpected `{:error, reason}` tuples,
so `Nebu.Matrix.Http.call_core/1` can translate `:internal` to a proper server-error response.

## Room GenServer Start on Demand (Story 11-11)

After a stack restart, Room GenServers are not automatically re-started - rooms exist in the DB
but have no running process in the Horde registry. Handlers that need an active Room GenServer
MUST use `start_room/1` (idempotent) rather than `lookup_room/1` (registry-only) to avoid
returning `404` for rooms that genuinely exist.

**Pattern:**

```elixir
case Nebu.Room.RoomSupervisor.start_room(room_id) do
  {:error, _reason} ->
    # Room does not exist in DB - Room.Server.init/1 returned {:stop, _}
    raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.not_found(), message: "room not found: #{room_id}"
  {:ok, _pid} ->
    # GenServer is running (either already was, or just started from DB)
    # ... proceed with room operation
end
```

**Idempotency invariant:** `RoomSupervisor.start_room/1` handles `{:error, {:already_started, pid}}`
internally and converts it to `{:ok, pid}`. Callers always receive either `{:ok, pid}` (GenServer
running) or `{:error, _}` (room absent from DB).

**`{:error, _}` wildcard trade-off:** Horde supervisor errors (e.g. `:max_children`) also map to
`not_found` via this pattern. This is an acceptable trade-off: such errors are rare, and the alternative
of forwarding an opaque `:internal` error is less useful to clients. The same trade-off applies
consistently across all handlers that use `start_room/1`.

**Race guard - `:noproc` after `start_room`:**

In rare cases, a GenServer may die between `start_room` returning `{:ok, pid}` and the subsequent
`get_state/1` call (e.g. during Horde CRDT reconciliation). Handlers that call `get_state` after
`start_room` MUST wrap that call in a `try/catch :exit, {:noproc, _}` guard to surface the failure
as `not_found` rather than a raw exit:

```elixir
state =
  try do
    room_registry_module().get_state(room_id)
  catch
    :exit, {:noproc, _} ->
      raise Nebu.Matrix.Error, status: Nebu.Matrix.Status.not_found(), message: "room not found: #{room_id}"
  end
```

**Handlers using `start_room` (not `lookup_room`):**

| Handler / function | Call site in `server.ex` |
|---|---|
| `sync.ex` - incremental sync | line ~1053 |
| `unarchive_room/2` | line ~1959 |
| `upgrade_room/2` - new room | line ~2487 |
| `send_receipt/2` | line ~662 (added Story 11-11) |

**Handlers intentionally using `lookup_room`** (started elsewhere in the same request lifecycle,
or explicitly requiring the GenServer to be pre-running):

All other handlers in `server.ex`. Migration of remaining handlers (e.g. `set_typing/2`) is
deferred to a separate story to keep diffs minimal and reviewable.

## Logging

**Elixir:** `Logger` with keyword metadata, structured key-value pairs.

PII (email, display name) must never appear in log output. Debug level never enabled in production.

## API Response Formats

**Strict separation:** Matrix endpoints return Matrix format; Admin API returns wrapper format.
No mixing.

```json
// Matrix API success
{"event_id": "$abc123", "room_id": "!xyz:server.name"}

// Admin API success
{"data": {...}, "meta": {"cursor": "v1_abc", "limit": 50}}

// Admin API error
{"error": {"code": "USER_NOT_FOUND", "message": "..."}}
```

## Admin UI Security

**Phoenix HTTP Controller + LiveView Admin (admin-ui-migration + admin-http-refactor — supersedes Go template admin):**

The Admin UI is now served by `Nebu.Web.AdminEndpoint` (Phoenix.Endpoint, `server: false`) forwarded
from `Nebu.Web.Router`. Key security controls:

- **Admin auth gate — two mechanisms:**
  - HTTP controllers use `Nebu.Admin.Auth.require_admin/2` as a Plug in the `:admin` pipeline.
  - Remaining LiveViews (Dashboard, AuditLog, Bootstrap) use `on_mount {Nebu.Admin.Auth, :require_admin}`.
  Both check the signed Phoenix session for a valid admin claim derived from
  `server_config.admin_group_claim` (default `instance_admin`) via an inline SQL check (ADR-018).
  Unauthenticated access is redirected to `/admin/login`.
- **CRUD page rendering (admin-http-refactor):** Users, Rooms, Spaces, Config, ClaimMapping,
  RoleMapping, and Compliance pages are now rendered by Phoenix HTTP controllers following the
  Post-Redirect-Get (PRG) pattern. Each controller module has a corresponding HTML view module and
  HEEx template. State changes are submitted as standard HTML form POSTs; the controller processes
  the request, writes to the DB via inline SQL (ADR-018), and redirects to the GET page. No
  persistent WebSocket is required for these pages.
- **Real-time LiveViews (unchanged):** DashboardLive, AuditLogLive, and BootstrapLive remain as
  Phoenix LiveViews — they require server-push or multi-step stateful interactions that benefit from
  the persistent WebSocket connection.
- **CSRF:** Phoenix `protect_from_forgery` with a signed session — applies to both HTTP controller
  form submissions (standard CSRF token in form) and LiveView event handlers (CSRF verified
  by Phoenix automatically).
- **Session cookie:** `http_only: true`, `secure: true` (config-driven; enforced in prod TLS). The
  Phoenix session is signed/encrypted with `secret_key_base`, derived from `NEBU_ADMIN_SECRET_KEY_BASE`
  or SHA-512 of the internal secret file. A missing `NEBU_ADMIN_SECRET_KEY_BASE` **raises at boot** in
  prod when the internal secret file is also absent (fail-closed).
- **Content-Security-Policy (admin browser pipeline):**
  `default-src 'self'; connect-src 'self' ws: wss:; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'self'`
  Applied as a Plug in the admin browser pipeline. `ws:/wss:` is required for the three remaining
  LiveViews (Dashboard, AuditLog, Bootstrap). `style-src 'unsafe-inline'` is required for Phoenix
  LiveView inline transition styles.
- **OIDC client secret at rest:** `BootstrapLive` encrypts the `oidc_client_secret` with AES-256-GCM
  before persisting to `server_config` (reuses `Nebu.Media.Crypto`; key = SHA-256 of internal
  secret; fail-closed when no secret is available). Byte-compatible with the existing Go
  `admin.EncryptAES256GCM` scheme (shared internal secret, same key derivation).
- **Phoenix.PubSub:** Added to `Nebu.Application` as a child process required by LiveView. Uses
  the `Phoenix.PubSub.PG2` adapter (in-process, no external broker — consistent with ADR-002).

**Admin login (go-removal-cleanup — complete):** The Go admin handlers are deleted; server owns the
full admin OIDC Authorization-Code + PKCE login in Elixir (`Nebu.Admin.Auth`). `/admin/login/start`
mints a PKCE verifier/S256 challenge + CSRF state + OIDC nonce into the signed Phoenix session and
redirects to the IdP; `/admin/callback` validates state (constant-time, fail-closed), exchanges the
code at the provider token endpoint, verifies the ID token via the shared
`Nebu.Web.Plugs.OidcPlug.verify_token/2` (signature/alg/iss/aud/exp/sub) + nonce binding, enforces the
admin-group claim, and mints the Phoenix admin session (`renew: true`, `session_exp = min(idToken.exp,
now+8h)`). There is one session cookie (the signed Phoenix `secret_key_base` cookie — http_only, secure,
SameSite=Lax). `NEBU_ADMIN_OIDC_LOGIN_URL` is removed; the admin OAuth client is configured via
`NEBU_ADMIN_OIDC_CLIENT_ID` / `..._CLIENT_SECRET[_FILE]` / `..._REDIRECT_URI`. When
`NEBU_ADMIN_OIDC_REDIRECT_URI` is not explicitly set, `Nebu.Admin.Auth` derives the default from
`NEBU_SERVER_NAME` + `NEBU_ADMIN_SESSION_SECURE`: `https://{server_name}/admin/callback` for
production (non-localhost) and `http://localhost:8008/admin/callback` for local dev. The value is
always server-controlled and never derived from request headers (Host/X-Forwarded-*).

**Admin silent OIDC token refresh (admin-oidc-session-refresh):** Admin login now requests
`offline_access` so the IdP returns a `refresh_token`. The RT is encrypted with `Nebu.Web.SecretBox`
(AES-256-GCM) and stored *inside* the signed admin session cookie — no `admin_sessions` DB row, no
plaintext RT at rest. On each authenticated HTTP request `Nebu.Admin.Auth.fetch_current_user/2`
silently refreshes within a 120 s pre-expiry window: it exchanges the stored RT at the token endpoint,
re-verifies the new `id_token` via `OidcPlug.verify_token`, **re-evaluates the admin-group gate on the
refreshed claims** (a revoked admin loses access on the next refresh), recomputes
`session_exp = min(new id_token.exp, now+8h)`, renews the session and rotates the stored RT. On refresh
failure or lost group it clears the session and redirects to `/admin/login`. This replaces the previous
behaviour where the admin session was capped at the short `id_token.exp` with no refresh, causing a
forced re-login roughly every 5 minutes against Keycloak. **Known limitation:** the refresh fires on
HTTP round-trips, not over the persistent LiveView websocket.

## Testing Architecture (Story 9-26)

Nebu uses a two-layer E2E test strategy, splitting tests by the level of observable behavior:

| Layer | Runner | Scope | Location |
|---|---|---|---|
| HTTP / Matrix API | ExUnit `:integration` (Plug.Test / `:httpc`) | REST endpoints, Matrix CS protocol | `server/test/nebu/matrix/` |
| Browser / UI | Playwright + `playwright-bdd` | Element Web flows, Admin UI, real OIDC redirects | `e2e/` |

**No plain `.spec.ts` files without a `.feature` counterpart are accepted for new stories.**
Gherkin `.feature` files are the single source of truth for all E2E scenarios.

### Browser-First E2E Layer

All browser-level tests use `playwright-bdd` as the execution engine. Feature files are defined
first (failing), step definitions implement them in TypeScript. The `playwright.config.ts` registers
three test projects:

- `chromium` - legacy API-contract tests (no BDD change)
- `admin-ui` - Admin UI BDD tests via `playwright-bdd`
- `element-web` - Element Web browser-first E2E via `playwright-bdd`

```
e2e/
  features/
    element/            ← login, room/{create,join,leave}, messages/{send,receive}
    admin/              ← bootstrap, dashboard, auth-guard, users, rooms, audit-log
  step-definitions/
    common/             ← auth, navigation, stack-health, room-setup, assertions (shared)
    element/            ← login, room, messages steps
    admin/              ← bootstrap, dashboard, users, rooms steps
  fixtures/
    users.ts            ← NEBU_USERS const (4 pre-configured Dex test users)
    dex-auth.ts         ← loginViaOidcBrowser(), ensureStorageState(), getApiSession()
    element-app.ts      ← ElementAppPage (Playwright page object for Element Web)
    nebu-fixtures.ts    ← createBdd(test) - exports { Given, When, Then }
  global-setup.ts       ← warms token sidecars + bootstraps admin before tests
```

### Token Sidecar Pattern for IndexedDB Sessions (Story 9-26b)

Element Web 1.11+ stores `mx_access_token` in **IndexedDB**, not localStorage. Playwright's
`storageState()` captures only localStorage and cookies - not IndexedDB. The token sidecar
pattern solves this:

1. `loginViaOidcBrowser()` intercepts the `POST /_matrix/client/v3/login` response via
   Playwright route interception, captures the `access_token` + `user_id` from the JSON body.
2. The token is written to `e2e/auth-state/{user}.token.json` (the "sidecar" file).
3. `getApiSession()` reads the sidecar to obtain a valid token for Matrix API setup calls
   (`createRoom`, `inviteUser`) - without touching localStorage or IndexedDB.
4. `global-setup.ts` warms sidecars for `alex`, `marie`, and `kai` before any test runs.
5. Each test context performs a **fresh OIDC browser login** (no storageState restore) because
   IndexedDB sessions cannot be injected via `browser.newContext({ storageState })`.

The `auth-state/` directory is gitignored. Sidecars expire after 12 hours (staleness check in
`ensureStorageState()`).

### API Seeding vs. UI Assertion Boundary

Matrix API calls via `page.request` are permitted in **Given/When (setup)** steps only:

| Step type | API calls allowed? | Rationale |
|---|---|---|
| `Given` - test pre-condition | Yes | Set up rooms, send invites, seed data |
| `When` - user action | No (UI only) | The feature under test |
| `Then` - assertion | No (UI only) | Assertions must target the visible UI |

Example for `room/join.feature`: kai creates the room and sends the invite via Matrix API
(`Given`), the assertion is that alex sees the invite banner in Element Web and clicks "Accept"
(`When`/`Then`).

### OIDC Authorization Code + PKCE Requirement

All Gherkin E2E tests use Authorization Code + PKCE. `grant_type=password` (ROPC) is not
supported by Dex v2.41+ and is forbidden in all tests. The consent screen is handled inside
`loginViaOidcBrowser()` (first login only) via a role-based button locator
(`/grant access|allow|approve|confirm/i`).

### Makefile Targets

```bash
make test-e2e-element   # element-web project (bddgen + playwright)
make test-e2e-admin     # admin-ui project (bddgen + playwright)
make test-e2e           # all projects (legacy + BDD)
```

## Thread Aggregations in Sync (Story 9-28)

Matrix spec §11.12 defines "bundled aggregations" - a mechanism for delivering relation metadata
(reply counts, latest replies) inline in a parent event's `unsigned.m.relations` field during sync,
avoiding extra HTTP round-trips from clients.

**How Nebu implements bundled aggregations for `m.thread`:**

1. `attach_thread_aggregations/3` is called for every list of timeline events returned from an
   initial sync or an incremental delta sync in Elixir Server.
2. For each event, it calls `count_thread_children(room_id, event_id)` and (when count > 0)
   fetches the latest reply via `fetch_events_by_relation/5` with `limit = 1` and empty opts.
3. The aggregation struct `%{"m.thread" => %{count: N, latest_event: %{...}, current_user_participated: bool}}`
   is JSON-encoded and stored in `Core.Event.unsigned_relations` (originally protobuf field 9; now a plain struct key).
4. In the Matrix sync handler, the event's `unsigned.m.relations` field is populated from the
   `unsigned_relations` value only when it is non-empty; absent relations produce no extra JSON key
   (the key is omitted entirely).

**Database invariant:** The expression index on `events((content->'m.relates_to'->>'event_id'))`
(migration 000042) is required; without it, `attach_thread_aggregations/3` would cause N sequential
scans per sync response (one per timeline event).

**Scope:** Only `m.thread` relation type is aggregated in the current implementation.
The `/relations` endpoint (`GetRelations` RPC) supports any `rel_type` (including empty for all
types) via `fetch_events_by_relation/5`'s dynamic WHERE builder. Element Web typically calls it
for `m.thread`. The function is parameterised on `rel_type` and `event_type` and can be extended
to other relation types (reactions, edits) in a future story.

## Relations API - Query Parameters (Story 9-29)

Story 9-29 extended the `GET /relations` handler with Matrix CS API-compliant query parameters
and two additional route variants:

| Parameter | Type | Default | Validation |
|---|---|---|---|
| `dir` | string | `"b"` | Must be `"f"` or `"b"`; `400 M_BAD_PARAM` otherwise |
| `limit` | integer | 20 | Clamped to 100; 0 uses default |
| `recurse` | boolean | false | Must be parseable; `400 M_BAD_PARAM` otherwise |
| `from` | string | `""` | Opaque pagination token; passed through to Server |

**dir semantics:** `"b"` (backward) = newest-first DESC; `"f"` (forward) = oldest-first ASC.
This mirrors the `GET /messages` semantics from the Matrix CS API spec.

**recurse=true:** Accepted without error (Matrix spec MUST requirement). MVP implementation
treats it the same as `dir=b`; true recursive relation traversal is deferred to Phase 2.

**prev_batch:** When using `dir=b` pagination, the response includes a `prev_batch` token in
`GetRelationsResponse` (field 3) allowing clients to page backwards. Currently always empty
(no prev-page cursor implemented in MVP); the field is present in the `Core.GetRelationsResponse`
struct for forward compatibility.

## Configurable OIDC Claim Mapping (Story 11-10)

Nebu operators can configure which OIDC claims map to Matrix user identity and profile fields
via the Admin UI settings page (`GET/POST /admin/config/claim-mapping`) or during the Bootstrap
Wizard (Step 3). Three keys are stored in `server_config`:

| Key | Default | Purpose |
|---|---|---|
| `oidc_user_id_claim` | `sub` | Claim used as the source for Matrix localpart derivation |
| `oidc_displayname_claim` | `name` | Claim used as the user's display name in Matrix profiles |
| `oidc_email_claim` | `email` | Claim used to populate the user's email profile field |

**Migration 000044** seeds these defaults into `server_config` using `INSERT … ON CONFLICT DO NOTHING`.
Existing deployments that already have these keys set manually are unaffected; new installs receive
the Nebu defaults automatically.

**`FormatUserIDFromClaims` refactored signature (AC6):**

```go
// Old: FormatUserIDFromClaims(sub, name, serverName string) string
// New:
func FormatUserIDFromClaims(claimName string, claims map[string]interface{}, serverName string) string
```

The function extracts `claims[claimName]` as a string, sanitises it via `sanitiseLocalpart`, and
returns `"@" + sanitised + ":" + serverName`. If the result is empty (claim absent, non-string, or
invalid characters), it falls back to `FormatUserID(sub, serverName)` - the SHA-256 opaque localpart
path - using `claims["sub"]` as input.

**Fallback chain (Elixir, `Nebu.Matrix.UserId.localpart/1`):**

1. `server_config.oidc_user_id_claim` (the operator-configured claim), served from
   `Nebu.Matrix.OidcClaimCache` (see below).
2. If unset/empty: the `preferred_username` claim.
3. then the `name` claim.
4. then `sub`; and if the chosen value sanitises to empty, `sub` is used as the final source.

**Claim cache (`Nebu.Matrix.OidcClaimCache`, story `oidc-claim-boot-cache`):** the Go gateway's
60-second-TTL `claimLoader` closure was removed with the Go stack. In the Elixir stack the configured
claim is cached in node-local `persistent_term` and read directly on the caller in `configured_claim/0`
— an O(1), lock-free read with **no DB round-trip on the request hot path** once populated. The cache is
populated **lazily on first read** (three states: `:unset` / `{:value, string}` / `{:value, nil}`), so a
confirmed value — including confirmed-absent — is never re-queried. Invalidation is **event-driven, not
TTL-based**: all three write paths route through `Nebu.Admin.DB.upsert_server_config/1`, which calls the
`Nebu.Matrix` public function `invalidate_oidc_claim_cache/0` when the `oidc_user_id_claim` key changes;
that re-reads the DB and broadcasts an invalidation to peer nodes over the `nebu_matrix_oidc_claim_cache`
`:pg` group (ADR-020 — identical behaviour single-node and clustered). This eliminates the per-request DB
read and the transient fail-open-to-weaker-claim window in steady state (residual bounded to the
node-start-until-first-successful-read cold-start window; SEC-reviewed and accepted).

**Claim name validation:** `oidcClaimNameRe` (`^[a-zA-Z0-9:_\-.]+$`, 1–50 chars) is applied to all
three claim fields on both the Admin UI POST handler and the Bootstrap Wizard Step 3. Invalid inputs
return HTTP 422 with per-field error messages.

**Identity stability warning:** The `oidc_user_id_claim` determines the permanent Matrix user ID.
Changing it post-bootstrap generates different Matrix IDs for existing OIDC principals, breaking all
their room memberships. The Admin UI settings page and Bootstrap Wizard Step 3 both display a
prominent warning banner about this consequence.

**Audit logging:** `ClaimMappingHandler.UpdateHandler` reads the previous values via `LoadClaimMapping`
before persisting and includes `previous_oidc_user_id_claim`, `previous_oidc_displayname_claim`, and
`previous_oidc_email_claim` in the `audit_logs` entry alongside the new values.

## Build Metadata Injection (Story 11-9)

Nebu exposes build metadata (`version`, `git_commit`, `build_time`) via a `GET /info` endpoint on the
application (port 4000). It requires no authentication and returns JSON:

```json
{"component": "nebu", "version": "0.1.0", "git_commit": "abc1234", "build_time": "2026-05-11T10:00:00Z"}
```

**Injection mechanism:** `ARG → ENV` in the Dockerfile; `Nebu.BuildInfo.get/0` reads `System.get_env/2`
at call time, defaulting to `"unknown"` when unset. Both the builder and runtime Dockerfile stages
carry the three `ENV` vars so the values are available whether baked into the release BEAM files or
read at process start.

**Admin UI footer:** The same build info is threaded into the shared admin layout so every authenticated
admin page (both HTTP controller pages and LiveViews) renders a footer of the form
`nebu v<version> · <git_commit> · built <build_time>`, suppressed on the login and error pages.

**`make redeploy` integration:** The `redeploy` Makefile target exports `GIT_COMMIT`
(from `git rev-parse --short HEAD`) and `BUILD_TIME` (from `date -u`) before calling
`docker compose build`. When these are unset (e.g. plain `make redeploy` without env
exports), `docker-compose.yml` passes `${GIT_COMMIT:-unknown}` - images build successfully
and `GET /info` returns `"unknown"` values per AC3.

## Relations API - JSONB Content Normalisation (Story 9-30)

**Bug fix:** Postgrex returns JSONB columns as a `%Postgrex.JSONB{decoded: map}` struct when the
column value is a JSON object. Prior to Story 9-30, `event_map_to_proto/1` in
`Nebu.Matrix.EventDispatcher.Server` only handled plain Elixir maps and binary strings, causing a
`Protocol.UndefinedError` (HTTP 500) whenever `/relations` was called on rooms
that stored events with JSONB-typed `content` columns.

**Fix:** A shape-based guard was added as the first branch in the `cond` inside
`event_map_to_proto/1`:

```elixir
is_struct(raw) and Map.has_key?(raw, :decoded) and is_map(raw.decoded) -> raw.decoded
```

This extracts `.decoded` before `Jason.encode!/1`. The guard precedes the `is_map/1` branch
because `%Postgrex.JSONB{}` structs also satisfy `is_map/1` (all structs are maps in Elixir).

**Normalisation contract - all three Postgrex return forms are now handled:**

| Postgrex return form | Guard matched | Action |
|---|---|---|
| `%Postgrex.JSONB{decoded: map}` | `is_struct and has :decoded` | Extract `.decoded` |
| Plain `%{...}` map | `is_map` | Use as-is |
| Binary `"..."` string | `is_binary` | `Jason.decode/1` |

**Shape matching rationale:** `Postgrex` is not a direct dependency of the `event_dispatcher` OTP
application. Matching by module name (`%Postgrex.JSONB{}`) would introduce a compile-time
dependency. The shape guard (`is_struct/1 + Map.has_key?(:decoded) + is_map(.decoded)`) is safe
because the `events.content` column round-trips through PostgreSQL JSONB - no user-supplied term
can produce an arbitrary Elixir struct with a `:decoded` key via this code path (Postgrex returns
native Elixir terms, not ETF-deserialised arbitrary structs).

**Scope:** The fix applies to every call site of `event_map_to_proto/1` - currently
`get_relations` (Story 9-29) and `get_messages`. No new endpoints, migrations, or
schema changes were introduced.

_Source: `_bmad-output/planning-artifacts/architecture.md`, §Cross-Cutting Concerns, §Auth-Token-Flow, §Enforcement; `_bmad-output/planning-artifacts/prd.md`, §Cryptographic Identity Architecture; Story 9-22 (per-device sync token isolation, logout cleanup); Story 9-26 (Browser-First E2E layer, playwright-bdd, token sidecar pattern); Story 9-27 (gRPC error surface rule - GRPC.RPCError vs MatchError; failure audit trail pattern for multi-step operations); Story 9-28 (Thread aggregations in sync, bundled m.thread via unsigned_relations, GetRelations RPC, migration 000042 expression index); Story 9-29 (Relations API query params: dir, recurse, from; base and three-segment routes; prev_batch response field; fetch_events_by_relation/5 dynamic WHERE builder with rel_type + event_type + dir opts); Story 9-30 (JSONB content normalisation bug fix - %Postgrex.JSONB{decoded} struct guard in event_map_to_proto/1; resolves /relations HTTP 500 on JSONB-typed content columns); Story 11-7 (SSO nonce-based replay prevention; Cache-Control: no-store on SSO 302 redirect; denylist check in PostLogin with 403 M_FORBIDDEN; ssoStateStore capacity cap at 10,000; Safari re-login bugfix); Story 11-9 (build metadata injection - ldflags for Go, ARG→ENV for Elixir; NewInfoHandler static pre-marshalled response; Nebu.BuildInfo.get/0; Admin UI footer via SetBuildInfo/newPageData/ErrorMode; make redeploy GIT_COMMIT/BUILD_TIME exports); Story 11-10 (configurable OIDC claim mapping - FormatUserIDFromClaims refactored signature, TTL-cached claimLoader, oidcClaimNameRe validation, migration 000044 defaults seed, identity-stability warning, audit log with previous values, Bootstrap Wizard Step 3, ClaimMappingHandler admin settings page); Story 11-11 (Room GenServer start-on-demand concept - send_receipt/2 lookup_room → start_room fix; {:error,_} wildcard trade-off; :noproc guard pattern; handler inventory for start_room vs lookup_room); Story 12-6 (blurhash pass-through contract - content.info is opaque JSONB, client extension fields preserved verbatim; animated=false MUST NOT return animated thumbnail regression test; explicit traceability tests for AC1+AC2); Story 12.16 (Authenticated media endpoints - auth.Middleware TokenVerifier interface, M_MISSING_TOKEN/M_UNKNOWN_TOKEN error codes, fail-closed nil-verifier guard; config.Handler media config endpoint; CSP + Cross-Origin-Resource-Policy headers on all download/thumbnail 200 responses; v3 unauthenticated + v1 authenticated routing pattern in main.go; {fileName} path value for Content-Disposition); Story 13-14 (squashed seed migration - FORCE RLS intentionally absent on audit_log in single-role model; append-only enforced at application layer; audit_log_purge SECURITY DEFINER bypasses RLS as table owner without BYPASSRLS); bugfix-sso-bootstrap-credentials (OIDC client credential source hierarchy - newServerConfigClientIDLoader / newServerConfigClientSecretLoader TTL-cached loaders; DB takes precedence over env var; AES-256-GCM decryption on secret load; slog.Warn on decrypt failure; startup observability check; LoginHandler ClientIDLoader/ClientSecretLoader API; resolveClientID/resolveClientSecret methods)_
