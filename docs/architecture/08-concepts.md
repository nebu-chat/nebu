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
- **`Nebu.Web.OidcConfig`** — a GenServer + ETS cache for OIDC issuer, audience, JWKS URI, and (since
  story `fix-and-configure-sso-redirect-schemes`) the Admin-UI-managed `sso_extra_redirect_schemes`
  string (additional trusted `redirectUrl` deep-link schemes for `SsoLogin.redirect_url_allowed?/1`,
  beyond the hardcoded defaults). **ADR-022: OIDC is configured EXCLUSIVELY via the Bootstrap Wizard**
  (`server_config`) — there is no environment-variable OIDC config path. `OidcPlug`, `JwksCache`,
  `SsoLogin`, and `Admin.Auth` resolve issuer/audience/JWKS-URI/SSO-schemes **solely** through this
  cache (and the bootstrap draft during the wizard flow). Caching in ETS `:nebu_http_oidc_config` avoids
  per-request DB lookups on the hot OIDC and SSO-redirect paths. The cache is refreshed both by the
  Bootstrap Wizard and by `Nebu.Admin.DB.upsert_server_config/1` (for post-bootstrap Admin UI edits,
  e.g. `/admin/config`) after configuration is written to `server_config`, and cluster-aware invalidation
  via `:pg` ensures all nodes stay synchronized (ADR-020, M-3). When `server_config` has no OIDC config
  (pre-bootstrap), the cache returns `nil` and every consumer **fails closed** (F-4 — all Bearer tokens
  rejected with 401; admin → `/bootstrap`); the SSO-schemes field independently defaults to `[]`
  (only the hardcoded scheme allowlist governs redirectUrl validation) rather than failing closed, since
  it is an additive allowlist extension, not an auth-critical value. A test-only `:oidc_config_source`
  seam injects values without a live DB.
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
- **`Nebu.Matrix.OidcMetadata` — MSC2965 discovery endpoint (bugfix-oidc-public-endpoint-urls):** `GET /_matrix/client/v1/auth_metadata` proxies and caches (5-min TTL) the OIDC provider's `/.well-known/openid-configuration` discovery document, with two architectural principles:

  **1. Honest issuer over response rewriting (config honesty):** the IdP is configured with its OWN publicly-resolvable issuer value (`issuer` in dev Dex's `config.yaml`, or a Keycloak realm URL), independent of how it is reached from Nebu's perspective (whether as an internal Docker-Compose service name or a public hostname). Dex/Keycloak bakes this SAME issuer into every URL in its discovery document (authorization_endpoint, token_endpoint, jwks_uri, issuer field itself, etc.), so the document is already honest and publicly-reachable by construction. This design was chosen INSTEAD of response rewriting (a rejected v1 approach that rewrote the document's origin fields at serve time) because rewriting is fragile: it desyncs the advertised `issuer` from the real `iss` claim baked into tokens, requires a hand-maintained per-IdP field allowlist, and still leaves unfixed endpoints that Dex never exposes. By contrast, honest configuration makes every URL correct at the source.

  **2. MSC2965 field synthesis (when absent):** Dex's discovery document genuinely omits 3 fields the MSC2965 profile (and the Matrix Dart SDK) require: `registration_endpoint`, `response_modes_supported`, `revocation_endpoint`. `Nebu.Matrix.OidcMetadata.ensure_msc2965_fields/2` fills in ONLY these three when missing (never rewriting any field the upstream document provides). `response_modes_supported` is a spec constant (`["query", "fragment"]` — no origin dependency). `registration_endpoint` and `revocation_endpoint` are synthesized as `<configured_issuer>/<placeholder_path>` (e.g. `http://dex.localtest.me:5556/dex/clients/register`) using the CONFIGURED issuer value from `server_config.oidc_issuer` (a trusted local value), NOT the upstream document's `issuer` field (which is attacker-influenced network input); preserving the issuer's path (e.g. `/dex`, `/realms/nebu`) ensures the synthesized URL stays inside the IdP's mount point. A malformed configured issuer → synthesis is skipped (fail-closed, synthesis omitted rather than serving a garbage URL).

  On any fetch/parse failure, `auth_metadata` returns 503 M_UNAVAILABLE without attempting to synthesize a fallback — no incorrect endpoint URLs are served. The raw discovery document is otherwise passed byte-for-byte when fetch succeeds, upholding the honest-issuer principle: Dex's response shapes exactly what browsers/clients see.
- **`GET /_matrix/client/v3/auth_issuer` (ADR-022):** a simple endpoint returning `{"issuer": <configured_issuer>}` read from the `OidcConfig` cache (the same `server_config` value) — fail-closed (503) until bootstrap configures it. This endpoint's behavior mirrors `auth_metadata` in architecture: it surfaces the configured issuer without rewriting, by construction.
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
(advertised IdP name for `POST /login` `m.login.sso`), `NEBU_RATE_LIMIT_DISABLED`, and
`NEBU_SERVER_NAME` (used to build the `@<sub>:<server_name>` Matrix user ID and to derive the admin
`/admin/callback` redirect_uri). Additional trusted SSO client redirect schemes (beyond the
hardcoded defaults `element`/`schildichat`/`im.fluffychat.auth`) are bootstrap-only, configured via
the Admin UI (`/admin/config`, `server_config.sso_extra_redirect_schemes`) — no env var
(story `fix-and-configure-sso-redirect-schemes`).

**SSO redirect scheme rejection: content-negotiated response (story
`sso-redirect-error-page/html-error-page-for-rejected-sso-redirect-scheme`):** when
`SsoLogin.redirect_url_allowed?/1` rejects a client's `redirectUrl` scheme, `GET
.../sso/redirect` and `.../sso/redirect/{idpId}` now content-negotiate the rejection
response on the request's `Accept` header — a real browser (the Matrix SSO flow always
opens one here) with an HTML-preferring `Accept` header gets a minimal static HTML error
page naming only the rejected **scheme** (never the full `redirectUrl`/host/path/query),
pointing to `/admin/config` → "SSO redirect schemes" to request support. Every other
Accept header (missing, `application/json`, bare `*/*`, or any ambiguous/tied preference)
still gets the exact pre-existing JSON `M_INVALID_PARAM` error, byte-for-byte — this
remains the guaranteed default per the CS API's standard-error-response rule. The scheme
is the only interpolated value and is explicitly escaped via `Plug.HTML.html_escape/1`;
the HTML response carries `Content-Security-Policy: default-src 'none'`. This is a
rejection-response-format change only — the allow/deny decision in
`redirect_url_allowed?/1` is untouched, as are `uia_fallback/1` and the OIDC callback.

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
operator-configured extra scopes (empty by default — no extra scopes unless the operator configured
them via Bootstrap Wizard or `/admin/config`); the Matrix SSO authorization request asks for
`openid` + operator-configured extra scopes (same: empty by default). Both add
`offline_access` when their configured refresh mode is `"offline"` (read live from `server_config`
via the `:matrix_oidc_refresh_mode_reader` / `admin_oidc_refresh_mode` seams). `openid` is always
mandatory (cannot be removed); all other scopes are **operator-configurable** via the Bootstrap
Wizard and `/admin/config` (Story configurable-oidc-scopes, `server_config` keys
`matrix_oidc_extra_scopes` / `admin_oidc_extra_scopes`). There is no `NEBU_OIDC_EXTRA_SCOPES` env
var (ADR-022: bootstrap-only config).

**`Nebu.Web.OidcScopes` (Story centralize-scope-resolution, epic oidc-simplification, 2026-07-01):**
scope resolution + validation for BOTH `Nebu.Matrix` and `Nebu.Admin` is centralized in a single
`Nebu.Web` shared-infra module (`server/lib/nebu/web/oidc_scopes.ex`), analogous to `OidcConfig` /
`JwksCache`:

- `resolve_scope(:matrix | :admin) :: String.t()` — `"openid"` + that client's OWN configured extra
  scopes + `"offline_access"` iff that client's OWN refresh mode is `"offline"`, deduplicated,
  space-separated. Reads through `Nebu.Web.OidcConfig`'s extended ETS cache (see below) — no ad-hoc
  SQL in `OidcScopes` itself.
- `validate_scope_string(String.t()) :: :ok | {:error, String.t()}` — the ONE validator
  (`~r/^[a-zA-Z0-9_:.\-]+\z/` per token), replacing the two previously-duplicated regex copies in
  `bootstrap_controller.ex` and `admin/auth.ex`.
- `Nebu.Matrix.SsoLogin.scope_list/0` and `Nebu.Admin.Auth.admin_oidc_scope/0` are now THIN
  DELEGATES to `OidcScopes.resolve_scope/1`; `bootstrap_controller.ex`/`config_controller.ex` call
  `OidcScopes.validate_scope_string/1` instead of a local regex.
- The existing four per-domain reader seams (`:{matrix,admin}_oidc_{extra_scopes,refresh_mode}_reader`)
  migrated house to `OidcScopes` UNCHANGED in name/shape, so the pre-existing regression suites keep
  passing without modification.

This supersedes the "Admin/Matrix identity unification" scope-union fold below: `Nebu.Matrix.matrix_oidc_extra_scopes/0`
(the Public-API facade delegate that fold used) is **removed** — see the dedicated note further down.

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

**OIDC Scopes Law (bugfix-remove-default-scopes):** extra scopes default to `""` (empty). When
`server_config` has no value (nil or missing row), the scope is `openid` only — no `profile`,
`email`, or `groups` defaults. Operators configure scopes explicitly via the Bootstrap Wizard or
`/admin/config`; only then are the configured scopes appended to `openid`.

| Client | Runtime key in `server_config` | Default (no row) |
|---|---|---|
| Matrix SSO | `matrix_oidc_extra_scopes` | `""` (openid only) |
| Admin login | `admin_oidc_extra_scopes` | `""` (openid only) |

Bootstrap Wizard writes explicit values; `/admin/config` allows runtime update without redeploy.

**Configurable OIDC Refresh Mode (Story oidc-refresh-mode-config):**

Whether the Matrix and Admin OIDC flows request a refresh token (`offline_access`) is **configurable
per client** rather than hardcoded. Two `server_config` keys, each `offline | online`, drive it:

| Key | Default | Builder reading it live | `offline_access` requested? |
|---|---|---|---|
| `matrix_oidc_refresh_mode` | `offline` | `Nebu.Matrix.SsoLogin.scope_list/0` → `Nebu.Web.OidcScopes.resolve_scope(:matrix)` | iff mode = `offline` |
| `admin_oidc_refresh_mode` | `online` | `Nebu.Admin.Auth.admin_oidc_scope/0` → `Nebu.Web.OidcScopes.resolve_scope(:admin)` | iff mode = `offline` |

- **Set at bootstrap** (Bootstrap Wizard) **and changeable at runtime** via `/admin/config`
  (`Nebu.Admin.ConfigLive`). Runtime changes apply to **subsequent logins** — no redeploy.
- Post-`centralize-scope-resolution`, `Nebu.Web.OidcScopes` reads the mode through
  `Nebu.Web.OidcConfig`'s shared ETS cache (or the injectable
  `:{matrix,admin}_oidc_refresh_mode_reader` seam in unit tests) instead of an ad-hoc per-call SQL
  query — an Admin-Config write to any of the 4 scope/refresh-mode keys now forces a synchronous
  cache refresh + `:pg` cluster broadcast via `Nebu.Admin.DB.upsert_server_config/1` (mirroring the
  `oidc_user_id_claim` cache-invalidation pattern), so a runtime change is visible on the very next
  login without a stale-cache window, even on multi-node deployments. `openid` is always mandatory;
  `offline_access` is appended only when the client's mode is `offline`.
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
| `matrix_oidc_extra_scopes` | `""` (empty) | `Nebu.Matrix.SsoLogin.scope_list/0` → `Nebu.Web.OidcScopes.resolve_scope(:matrix)` |
| `admin_oidc_extra_scopes` | `""` (empty) | `Nebu.Admin.Auth.admin_oidc_scope/0` → `Nebu.Web.OidcScopes.resolve_scope(:admin)` |

- **`openid` is always injected** by `Nebu.Web.OidcScopes.resolve_scope/1` — it cannot be removed by
  operator config, and no literal scope beyond `"openid"` is ever hardcoded there (OIDC Scopes Law,
  mechanically pinned by a grep test in `oidc_scopes_test.exs`).
- `offline_access` is still controlled by `{matrix,admin}_oidc_refresh_mode`, and — as of
  `centralize-scope-resolution` — is scoped strictly to each client's OWN refresh mode; it can no
  longer be requested by one client via the other's `*_extra_scopes` configuration (see the
  superseded identity-unification note below for the leak this closes).
- Scope tokens are validated against `[a-zA-Z0-9_:.\-]+` (anchored with `\z` — trailing-newline
  safe) via the ONE validator, `Nebu.Web.OidcScopes.validate_scope_string/1`, at every write boundary
  (bootstrap wizard, admin config page, bootstrap promotion) — no local regex copies remain.
- Migration `000013` extends the `config_update_mutable` RLS policy to include both new keys,
  mirroring the `000007` pattern for refresh-mode keys.
- Runtime injection via `:{matrix,admin}_oidc_extra_scopes_reader` seams (0-arity fun) mirrors the
  `:{matrix,admin}_oidc_refresh_mode_reader` pattern for test isolation; both pairs of seams now live
  on `Nebu.Web.OidcScopes` (unchanged name/shape) rather than being duplicated per domain module.

**Bootstrap-mode scope carve-out (bugfix-bootstrap-scope-ignored, 2026-07-09):** the table above
(`admin_oidc_extra_scopes` → `server_config`) only applies to the admin client's **post-bootstrap**
login. During the wizard itself, `server_config.admin_oidc_extra_scopes` does not exist yet — it is
only written by `do_complete_bootstrap` at the very end — so `Nebu.Admin.Auth.oidc_config("bootstrap")`
cannot use `admin_oidc_scope/0` (it would always see an empty value and request `openid` only,
ignoring whatever the operator just typed into Step 3's "Admin client scopes" field). It instead calls
`Nebu.Web.OidcScopes.resolve_scope_with_extra(:admin, draft["admin_oidc_extra_scopes"])`, reading the
value straight from the in-progress `bootstrap_draft`. `resolve_scope_with_extra/2` composes the
scope identically to `resolve_scope/1` (same `openid` + extras + refresh-mode-gated `offline_access`
rule) but takes the extras value as an argument instead of reading a fixed seam — and, since that
argument is no longer forced through a validated trust boundary, it re-validates it itself
(`validate_scope_string/1`, fail-closed to `openid`-only on an invalid string) rather than trusting
every call site. Bootstrap-mode's refresh-mode side is unaffected by this fix and still reads
`server_config`/the reader (a known, deliberately out-of-scope, same-class gap for a future story).

**Admin/Matrix identity unification (bugfix-unify-admin-matrix-oidc-identity, 2026-07-01) — SUPERSEDED
by story `centralize-scope-resolution` (same date):**
Because `matrix_oidc_extra_scopes` and `admin_oidc_extra_scopes` are independently configurable,
an operator could set them to different values — e.g. Matrix requests `profile` (so
`preferred_username`/`name` resolve) while Admin requests only `groups`. The SAME real person then
gets ID tokens with different claim sets from the two flows, and `Nebu.Matrix.UserId.from_claims/2`
(claim-priority: configured claim → `preferred_username` → `name` → `sub`) derives **two different**
Matrix user_ids for one person — a split identity, visible as two rows in the admin Users list.

Original fix: `Nebu.Admin.Auth.admin_oidc_scope/0` unioned its own configured extra scopes with the
Matrix flow's (`Nebu.Matrix.matrix_oidc_extra_scopes/0`, exposed via the `Nebu.Matrix` facade per
ADR-020), guaranteeing the admin ID token was always a claim-superset of the Matrix ID token.

**This fold is REMOVED as of `centralize-scope-resolution`** (2026-07-01): it was itself the root
cause of a Kassandra LOW finding (AC3 of that story) — `offline_access` configured under
`matrix_oidc_extra_scopes` could leak into the Admin OIDC request via the unfiltered fold, even when
the admin client's own refresh mode was `"online"`. `Nebu.Admin.Auth.union_scopes/2` and the
`Nebu.Matrix.matrix_oidc_extra_scopes/0` facade delegate are both deleted; `Nebu.Web.OidcScopes`
resolves each client's scope from ONLY that client's own `server_config` keys — no cross-client
union. An operator who independently configures `matrix_oidc_extra_scopes` and
`admin_oidc_extra_scopes` can once again see two different Matrix user_ids for the same person (the
original bug this fold fixed); identity/claim unification across independently-scoped flows is
tracked as a separate, claim-mapping-centric follow-up (see `centralize-scope-resolution`'s
Non-Goals: "Kein Claim-Mapping"), not re-solved via scope folding.

**Known limitation (historical, from the original fix):** it prevented NEW divergence only, never
retroactively merged identities that already split under the old drift in an existing deployment
(room memberships, devices, and audit-log actor rows tied to a stray opaque-`sub` user_id remain
untouched either way). Kassandra's non-blocking MEDIUM about the admin `admin_claim?/1` any-key scan
seeing a wider claim set is now largely moot for admin logins (the admin scope no longer widens via
the Matrix fold); the underlying any-key-scan risk itself is RESOLVED by story
`scope-admin-claim-to-path` (2026-07-02, see the "Path-scoped gate" note above) for deployments that
have (re-)run bootstrap claim selection since — pre-existing deployments remain on the documented
fallback until they do.

**Bootstrap-completion session identity fix (Story fix-bootstrap-admin-session-identity, epic
oidc-simplification, 2026-07-01):**

A second, independent `matrix_user_id`-divergence class from the one above: `Nebu.Admin.Auth.
bootstrap_confirm_claim/2` (the handler for `POST /admin/bootstrap/select-claim`, which completes
the setup wizard) minted the admin session via a **second, hand-rolled** `user` map
(`sub`/`email`/`admin`/`session_exp`/`refresh_grace_exp`) that never included `"matrix_user_id"` —
unlike `put_current_user/2` (used by the ordinary `normal_callback/2` login), which derives it via
`Nebu.Matrix.UserId.from_claims/2`. An operator who created a room via the Admin UI immediately
after finishing bootstrap (before ever logging in as a Matrix client) was attributed as the raw
opaque OIDC `sub` instead of their canonical Matrix user_id — `RoomsController.actor_id/1` /
`UsersController.actor_id/1` both fall back to `sub` when `matrix_user_id` is absent/empty.

**Fix:** `bootstrap_confirm_claim/2` now mints the session via the SAME `put_current_user/2`
builder `normal_callback/2` uses — no second map construction. Making this possible required
extending what the bootstrap draft carries: `bootstrap_callback/2` (the OIDC-callback leg, mode
`"bootstrap"`) now additionally stashes the FULL verified ID-token claims map as JSON under a new
draft key `bootstrap_full_claims` (the pre-existing `bootstrap_claims` key is a dot-path-flattened
projection built for the claim-picker UI and is not usable as input to `UserId.from_claims/2`'s
flat-key lookups; both keys are kept, serving their separate purposes). A private
`bootstrap_claims/1` decodes `bootstrap_full_claims`, falling back to reconstructing a flat claims
map from the legacy flattened `bootstrap_claims` list (bare/non-dot-path keys only) for a bootstrap
that was already in-flight when this fix deployed — this keeps such an in-flight setup from being
bricked. The reconstruction/decode-failure guard is checked in `bootstrap_confirm_claim/2`'s `cond`
chain BEFORE `complete_bootstrap/2` runs, so `bootstrap_completed` can never be set `"true"` from a
state that would then fail to mint a session.

Because both login paths now converge on one builder with the same claims-derivation logic, the
guarantee that a bootstrap-completion session's `matrix_user_id` equals a subsequent normal
re-login's is now **structural** (one shared code path), not incidental — the same closure this
story's sibling `bugfix-unify-admin-matrix-oidc-identity`/`centralize-scope-resolution` sought for
scope-driven claim divergence, but for a session-construction duplication instead.

**Considered and rejected:** a defense-in-depth fallback in `RoomsController.actor_id/1` /
`UsersController.actor_id/1` that would derive `matrix_user_id` from a synthetic `sub`/`email`-only
claims map when the session lacks `matrix_user_id` (e.g. a stale session minted before this fix
deploys), instead of falling back to the raw `sub`. Rejected in code review: for an instance with a
non-default `oidc_user_id_claim` (e.g. `preferred_username`), that claim is absent from a stale
session, so the fallback would have silently derived a *plausible but wrong* Matrix user_id — worse
than today's visibly-wrong raw-`sub` fallback, which at least fails obviously. `actor_id/1` in both
controllers ships unchanged. The residual — a session minted before this fix deploys still shows
the pre-fix behavior until the operator's next login — is bounded (sessions are TTL-capped) and
self-healing (every session minted after deployment now carries `matrix_user_id`), not a new or
worse exposure. Kassandra SEC Gate 1: CLEAN (see
`docs/stories/oidc-simplification/security-reports/fix-bootstrap-admin-session-identity-security-review-2026-07-01.md`).

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

When the bearer token contains a dot, routing continues on the existing OIDC JWT path (backward compat); if the raw JWT has expired, `call_jwt/2` returns `401 M_UNKNOWN_TOKEN` with `soft_logout: true` (matching the opaque-session expiry path's behavior), allowing clients to recover via re-authentication.

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

**Requested-but-not-granted fallback (Story fix-matrix-login-missing-refresh-token):** if the client
DOES send `refresh_token: true` but the IdP's token response carries no `refresh_token` despite
`offline_access` having been requested (e.g. the Keycloak client lacks the "Offline Access"
capability — an IdP-side misconfiguration, not a Nebu bug per RFC 6749 §3.3, granting fewer scopes
than requested is legal), the login silently degrades to the same JWT-only response as the
omitted-flag case above (no session row, no `refresh_token`/`expires_in_ms` in the response — both
spec-OPTIONAL per Matrix v1.3). This was previously a silent WARNING with no actionable detail;
`respond_login/7`'s fallback now logs a message with the same information content as the admin-side
parity message (`Nebu.Admin.Auth.store_refresh_token/2`): *"...ensure the IdP grants offline_access
to the matrix client"* — naming the specific client an operator needs to reconfigure, without
logging any token/id_token content. Investigating this diagnosability gap confirmed
`Nebu.Web.OidcScopes.resolve_scope/1` and `Nebu.Matrix.SsoLogin.extract_id_token/1` were already
correct (no scope-construction or parsing bug existed) — the fix is diagnosis-only, not behavioral.
A distinct follow-up story (`matrix-refresh-revalidates-with-idp`, now implemented — see below) tracked
the separately-identified observation that `/refresh` extended sessions purely locally and never
re-contacted the OIDC token endpoint.

**Session refresh (`POST /_matrix/client/v3/refresh`) — now IdP-revalidating (story
`matrix-refresh-revalidates-with-idp`):**

Registered OUTSIDE the auth pipeline (unauthenticated by spec) but **rate-limited** via the per-IP
`Nebu.Web.Plugs.RateLimit` token bucket. `/refresh` no longer just extends the Nebu-local opaque
session — it now re-validates against the OIDC provider on **every** refresh, closing the Matrix-side
"Nebu loses its OIDC-resource-server posture" gap the Oracle flagged: the admin refresh path
(`Nebu.Admin.Auth.refresh_admin_session/1`) already re-contacted the IdP on every silent refresh;
Matrix previously did not, leaving up to 8h between a deprovisioning event at the IdP and Nebu
noticing it (`deactivate_user`'s immediate opaque-session hard-delete was the only other kill-switch).
That detection-latency gap is now "next refresh attempt", matching the admin side:

1. Extract `refresh_token` from the request body; look up the session (including grace-window state).
   Not found / grace-expired → `401 M_UNKNOWN_TOKEN` with `soft_logout: true` (unchanged).
2. **(AC1) IdP re-validation, BEFORE any local rotation:** decrypt the session's stored
   `oidc_refresh_token` (`Nebu.Web.SecretBox`) and redeem it at the IdP token endpoint
   (`grant_type=refresh_token`) via the shared `Nebu.Web.OidcTokenExchange.refresh/2` — the SAME
   HTTP-POST + response-parse + `Nebu.Web.Plugs.OidcPlug.verify_token/2` logic
   `Nebu.Admin.Auth.exchange_refresh_token/1` uses (extracted once, called by both domains — no second
   independent copy). A `:matrix_oidc_refresh_override` test seam (1-arity fun over the decrypted RT,
   mirroring `:admin_oidc_refresh_override`) short-circuits the HTTP+JWT-verify leg in tests.
3. **(AC2) Fail-closed on ANY failure, with two distinct branches depending on WHY it failed** — IdP
   rejection/network error, decrypt failure, no stored OIDC RT, or the user having since been
   deactivated (re-checked via the SAME `Nebu.Matrix.Session.TokenValidator.validate/4` gate the login
   path uses) all respond `401 M_UNKNOWN_TOKEN` with `soft_logout: true`. What happens to the opaque
   session row differs:
   - **Confirmed rejection/deprovisioning** (IdP rejects the RT, decrypt failure, no stored OIDC RT, or
     a confirmed `{:error, :deactivated}` verdict): immediately hard-delete the opaque session row for
     that `(user_id, device_id)` (`MatrixSessionStore.delete_for_user_device/2`) so neither a retried
     `/refresh` nor the still-live old opaque access token can succeed afterwards.
   - **Transient re-check failure** (`check_still_active/2`'s call to `TokenValidator.validate/4` fails
     with anything other than a confirmed `{:error, :deactivated}` — e.g. a DB hiccup — wrapped as
     `{:error, {:transient_check_failed, reason}}`): this is NOT proof of deprovisioning, so the session
     row is left intact. This one request still fails closed (401), but a later `/refresh` attempt can
     succeed once the transient issue clears, instead of a legitimate session being permanently killed
     over an unrelated infra blip.

   There is no local-only fallback in either branch — a failed IdP round-trip never silently degrades
   to the old purely-local extension behavior.
4. **(AC3) On success**, the new opaque tokens' lifetime is computed via the SAME
   `session_expires_at/1` function login uses (`min(fresh_id_token.exp, now + ceiling)`), fed the
   FRESH claims returned by the IdP round-trip — not a flat ceiling. This restores login/refresh
   lifetime symmetry (previously an asymmetry the Oracle had flagged) as a side effect of the IdP now
   genuinely being asked on every refresh.
5. **(AC4)** A provider-rotated OIDC refresh token (some IdPs rotate on refresh, some don't) is
   re-encrypted and threaded through `MatrixSessionStore.rotate_tokens/1`'s pre-existing
   `:new_oidc_refresh_token` param; when the IdP returns none, the previous encrypted OIDC RT is
   carried over unchanged (that carry-over was already `rotate_tokens/1`'s behavior — this story is
   the first caller to ever actually populate the fresh-RT side of it).
6. Rotate atomically: write the new opaque tokens and mark the old row `revoked_at = NOW()`,
   `grace_until = NOW() + 60s` (unchanged, `rotate_tokens/1`).
7. Return `200 {"access_token", "refresh_token", "expires_in_ms"}`.

**Shared IdP token exchange (`Nebu.Web.OidcTokenExchange`):** extracts the ~20-line
`grant_type=refresh_token` HTTP-POST + JSON-parse + `verify_token/2` leg out of
`Nebu.Admin.Auth.exchange_refresh_token/1` into a module both the Admin and Matrix refresh paths call
with their own resolved config (issuer/client_id/client_secret) — same pattern as
`centralize-scope-resolution`/`centralize-claim-resolution`, applied to the refresh grant. Each domain
keeps its OWN test seam (`:admin_oidc_refresh_override` / `:matrix_oidc_refresh_override`) since
audience/client-config context can differ between the two flows.

**Server-paced background refresh worker (`Nebu.Matrix.Session.RefreshWorker`, story
`server-paced-session-refresh/background-session-refresh-worker`):**

The client-driven `/refresh` flow above only extends a session when the client actually calls it.
Element Web's legacy SSO redirect + token-login path never does — it never sends `refresh_token: true`
at login and never calls `/refresh` — so an opaque session issued that way was previously fire-and-forget:
it simply expired at its initial `expires_at` bound with no further extension.

`RefreshWorker` is a plain `GenServer` (ADR-018/ADR-021 — inline SQL, no Repository/Service layer,
`Process.send_after` scheduling loop, same template as `Nebu.Matrix.Session.Sweeper`), registered in the
supervision tree alongside `Sweeper` under `Nebu.Repo`'s children (`server/lib/nebu/application.ex`), so
neither starts without a DB. Each cycle:

1. **Selects candidates** — `matrix_sessions` rows with `revoked_at IS NULL` and `expires_at` within a
   configurable lookahead window of `NOW()` (`NEBU_MATRIX_REFRESH_WORKER_LOOKAHEAD_SECONDS`, default 1h).
   Since `rotate_tokens/1` always soft-revokes the old row in the same transaction as inserting the new
   one, at most one non-revoked row exists per device at a time — a plain `revoked_at IS NULL` filter
   already excludes every grace-period sibling, so a stale rotated-away row is never touched.
2. **Re-checks per row (TOCTOU-safe)** immediately before calling the IdP — re-selects by `access_token`
   and skips silently (no-op, no resurrection) if the row was deleted or revoked since step 1 (e.g. by
   `delete_one_device` or a racing client-driven refresh).
3. **Redeems via the SAME reused logic** as the client-driven path — `HttpPublic.revalidate_with_idp/1`
   and `MatrixSessionStore.rotate_tokens/1` — no second, parallel IdP-exchange implementation.
4. **On success**, the new `expires_at` is computed by the SAME `session_expires_at/1` cap login/`/refresh`
   already use (`min(fresh_oidc_exp, now + ceiling)`) — never unbounded, never a separately-invented rule.
5. **On failure**, only a CONFIRMED upstream rejection/deprovisioning signal (e.g. `:deactivated`, an
   explicit IdP rejection of that refresh token, decrypt failure) hard-deletes the session row — scoped to
   the EXACT row just acted on (`MatrixSessionStore.delete_by_access_token/1`, guarded
   `WHERE access_token = $1 AND revoked_at IS NULL`), **not** the wider `delete_for_user_device/2`. This
   narrower scope matters specifically for this worker: under clustering (ADR-020), multiple nodes may race
   to redeem the same rotating upstream refresh token, and a losing node's failure must not be able to
   reach across and delete the winning node's freshly-rotated replacement row. A merely TRANSIENT error
   (DB hiccup, IdP unreachable/discovery failure, IdP 5xx/429) is NOT treated as rejection — the row is left
   intact and simply expires via the bounded TTL if the transient condition persists, avoiding a brief IdP
   outage or rolling restart turning into a mass, self-inflicted hard-delete of every near-expiry session
   in that cycle.

**Orthogonal to the per-request liveness check:** the existing ≤60s deactivation/revocation check in
`OidcPlug.call_opaque/1` (via `provision/2`) is completely unmodified — the worker's interval does not
replace it, lengthen it, or otherwise interact with it. Delete-on-deactivation remains the fast path;
the worker's bounded rolling TTL remains the fail-safe ceiling if a delete is ever missed. No new ADR:
this is additive hardening of the existing legacy-login session-refresh path, not a new architectural
decision.

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

## Operational Logging

**Separation from audit logs:** `Nebu.Web.LogStore` manages a **mutable, pruneable operational log store** (`operational_logs` table) that is EXPLICITLY SEPARATE from `Nebu.Compliance.AuditLog` (the immutable, tamper-evident audit trail). Audit logs have a compliance contract (legal hold, tamper evidence); operational logs are transient diagnostics for operator troubleshooting — merging them would force audit logs to inherit a TTL deletion policy (bad for compliance) or operational logs to inherit expensive immutability (unnecessary complexity under churn).

**Central logger handler:** instead of scattered `Logger.*` calls deciding independently whether to persist, a single Erlang `:logger` handler (attached at boot via `Nebu.Web.LogStore.attach_handler/0`) intercepts **every** `Logger.*` call app-wide and is the sole decision point:
1. **Always:** broadcasts via `Phoenix.PubSub.broadcast/3` to topic `"operational_logs"` (feeds live-view subscriptions, independent of persistence)
2. **Conditionally:** queues entries via `GenServer.cast/2` to `Nebu.Web.LogStore.Writer` for batched insertion, scoped by `server_config` policy

The handler runs **synchronously** in the calling process (standard `:logger` behaviour) but performs NO blocking DB I/O — instead, it delegates to a buffering GenServer (non-blocking `cast`) so that `Logger` calls on hot paths (e.g. inside `Nebu.Repo.QueryTelemetry`'s telemetry callback, where a live DB read would deadlock the connection pool) remain fast.

**Levels and persistence:** 
- `WARN` and `ERROR`: always persisted (no toggle). Since story `admin-logs-retention-settings`, these two levels also get a hardcoded, **non-admin-configurable** 90-day safety-net TTL (no `server_config` key, no UI control — AC6 explicitly forbids one) so this tier is no longer unbounded, closing a gap flagged during the `operational-log-store` review.
  - **ERROR-always-persists exception (story `trace-map-node-controls`):** Entry level is checked before endpoint-tier policy — ERROR entries persist to `operational_logs` **unconditionally**, regardless of whether the endpoint is in the long-polling "off-by-default" list. This ensures a silently-off zone never hides failures: if an off-list endpoint encounters an error, the error is logged and propagates to the Trace Map (node renders with error status), making the silent zone visibly alarming to operators.
- `INFO` and `DEBUG`: persisted only if enabled via `server_config` keys (`log_collect_info`, `log_collect_debug`); off-list endpoints (long-polling: sync, keepalive, health) suppress DEBUG/INFO collection by default
- Retention per level: TTL (`log_retention_*_days`) + max-count cap, purged hourly via `Nebu.Matrix.Session.Sweeper`'s existing sweep cycle. The max-count cap was DEBUG-only at first; story `admin-logs-retention-settings` added the symmetric `log_retention_info_max_count` key so INFO now has the same two-dimensional (days + count) retention control as DEBUG.

**Request ID and route template propagation:** `Nebu.Web.Plugs.RequestLogger` calls `Logger.metadata(request_id: request_id, route_template: route_template)` early in the pipeline so all downstream `Logger.*` calls automatically carry them. `route_template` is normalized via position-based pattern matching (room/user/event ID segments → placeholders, e.g. `/rooms/:room_id/send/:event_type/:txn_id`) rather than fragile regex matching, enabling endpoint-level log aggregation.

**Policy cache:** `Nebu.Web.LogStore.PolicyCache` caches the `server_config` log-policy keys (6, since `admin-logs-retention-settings` added `log_retention_info_max_count`) in `persistent_term` to avoid a `Nebu.Repo` connection-pool re-entrancy bug (the handler runs synchronously inside `Nebu.Repo.QueryTelemetry`'s own telemetry callback, so a synchronous DB read there would deadlock the pool). The cache is refreshed on-write and on a periodic timer.

**Schema:**
```sql
CREATE TABLE war_room_sessions (
  id               UUID PRIMARY KEY,
  started_by       TEXT NOT NULL,               -- admin user ID
  reason           TEXT,
  scope            TEXT,                        -- "all" | route_template (e.g. "/_matrix/client/v3/sync")
  exclusive_scope  JSONB,                       -- nullable list of endpoints to exclude: ["/_matrix/client/v3/sync", "/health", ...]
  filter           JSONB,                       -- optional {user_id, device_id} AND-matched against entry metadata
  max_entries      INTEGER NOT NULL,            -- 10..10,000 (enforced at API boundary, ADR-018)
  max_duration_s   INTEGER NOT NULL,            -- 10..3600 (enforced at API boundary)
  entries_collected INTEGER DEFAULT 0,
  started_at       TIMESTAMPTZ NOT NULL,
  ended_at         TIMESTAMPTZ,                 -- NULL while active; set on exhaustion or duration timeout
  ended_reason     TEXT                         -- "budget_exhausted" | "duration_exceeded" | "manual_stop"
);

CREATE TABLE operational_logs (
  id             BIGSERIAL PRIMARY KEY,
  inserted_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  level          TEXT NOT NULL,        -- "debug" | "info" | "warning" | "error"
  source         TEXT NOT NULL,        -- "http" | "ecto" | module name
  route_template TEXT,                 -- normalized, e.g. "/rooms/:room_id/send/:event_type/:txn_id"
  request_id     TEXT,
  message        TEXT NOT NULL,
  metadata       JSONB,                -- domain-specific data (already redacted upstream)
  war_room_id    UUID                  -- nullable, extension seam for war-room-mode story; FK→war_room_sessions(id)
);
```

**exclusive_scope in war_room_sessions (Story `war-room-dedicated-page`):**
When an operator pre-scopes a session with "exclusive mode" (AC9), the `exclusive_scope` column holds a non-empty list of route_template strings to EXCLUDE from capture. When `Nebu.Web.LogStore.WarRoom.check/1` evaluates an entry for tagging, it checks:
1. Does the entry's `route_template` match the session's `scope` (as before, inclusive scope)?
2. Is the `route_template` in `exclusive_scope` (AC10)? If yes, SKIP (do not tag).
3. Does the `filter` (if present) match `metadata["user_id"]`/`["device_id"]` AND-wise?

If all three conditions pass, the entry is tagged with `war_room_id` and persisted. This avoids the common "I only wanted /sync excluded" scenario by allowing an operator to say "capture everything except these noisy endpoints" rather than laboriously enumerating what they *do* want. Pre-populated defaults from `Nebu.Admin.LogsLive.TraceMap.long_polling_endpoints/0` (the canonical endpoint list) are offered as checkbox options in the War Room form; an operator may also type a custom route if needed (validated server-side — untrusted client input, ADR-018 defense-in-depth).

**Admin UI monitoring consumption layer (`Nebu.Admin.LogsLive`, story `admin-logs-monitoring-view`):**

The operational log store's live broadcast is consumed by the Admin UI at `/admin/logs` (`Nebu.Admin.LogsLive` LiveView), which groups operational logs by `request_id` and presents one row per request, enabling operators to diagnose production issues without leaving the admin dashboard. The view subscribes to the `"operational_logs"` PubSub topic and applies log filters with two dimensions: **Level** (flat bubble list) and **Source** (flat bubble list). The filter state is a real, persistent LiveView socket assign, `@active_filters` — a map of `dimension => [values]` supporting same-dimension multi-select (e.g. `level=error` OR `level=warning`). Each bubble's `phx-click` triggers both instant client-side visual feedback via `Phoenix.LiveView.JS.dispatch` (zero perceived lag for interactivity) AND a `JS.push("toggle_filter"/"remove_filter", ...)` that updates the server-side assign via new event handlers in `LogsLive`. Filter state is also reflected in the page URL as comma-joined query params (e.g. `?level=error,warning`) via client-side `history.pushState`, making the filtered view reloadable and shareable. Browser back/forward triggers a new `handle_event("sync_filters", ...)` push to keep the server assign in sync with URL-driven navigation. A shared `reject_off_tier/3` helper guards all three write paths (mount-time URL seeding, `toggle_filter`, `sync_filters`) against activating a dimension value not currently collected per the retention policy. This fixes a latent bug in the prior pure-client-side design: unrelated re-renders silently reset filters since the server never tracked click state. The view streams requests sorted by severity then recency. A detail panel shows the full chronological thread for a request_id. The Endpoint dimension (hierarchical tree filtering) was retired in story `trace-map-leitstand` and is now a dedicated, full-page LiveView at `/admin/logs/trace-map`. Additionally, this story fixes two logging-pipeline gaps: (1) `Nebu.Web.Plugs.RequestLogger` now places `method`/`status`/`duration_ms` into structured `Logger.metadata/1` so these fields reach the operational log store as metadata (not just inspect'd message text), and (2) `Nebu.Web.LogStore.Handler.source_from_meta/1` now derives the calling module from Logger's `:mfa` metadata tuple rather than a nonexistent bare `:module` key, so "http"/"ecto" source classification works correctly in production log ingestion.

**Admin UI collection-policy configuration layer (`Nebu.Admin.LogsController`, story `admin-logs-retention-settings`):**

Where `Nebu.Admin.LogsLive` (above) is a read-only view of the collection policy, `GET /admin/logs/config` / `POST /admin/logs/config/retention` (`Nebu.Admin.LogsController` + `Nebu.Admin.LogsConfigHTML`) let an operator actually *change* it — reached via a "Sammlung konfigurieren →" link on the monitoring page, deliberately nested under `/admin/logs` rather than the generic `/admin/config` page (config UI lives next to where it's used, not in a catch-all). It is a deliberate, literal plain Phoenix Controller, **not** a LiveView, following `Nebu.Admin.ConfigController`'s exact GET/POST/flash/redirect pattern. WARN and ERROR render as non-interactive, always-on bubbles (no UI control exists for them, matching their hardcoded safety-net TTL above); INFO and DEBUG render as clickable toggle buttons that, when turned on, reveal inline retention fields (days, max entries) — DEBUG additionally shows a fixed warning about payload volume and high-frequency capture, referencing a not-yet-built "War Room mode" by name as a forward-compatible placeholder. Because there is no LiveView socket on this page, all of the toggle/reveal/pre-fill/warning interactivity (AC7/AC8/AC11) is implemented client-side in a new `wireLogsConfigToggles()` function in `server/priv/static/assets/app.js`, using the same delegated-listener, CSP-safe pattern (`script-src 'self'`, no inline handlers) as the page's other JS-driven admin widgets; the actual persistence round-trip is a real native form POST, validated and normalized server-side (blank or `"0"` always means "no limit" for that dimension, unconditionally — the 7-day/1000-entry defaults from AC8 are a client-side pre-fill convenience only, never a server-side fallback). Cross-tab consistency between this settings page and the monitoring view's bubble state (AC17) is implemented as Option A for this story: no PubSub, the monitoring page reflects a changed policy only on its next manual reload.

**War Room Mode — bounded, self-terminating diagnostic sessions (story `war-room-mode`, final story of the enhanced-logging epic):**

The DEBUG collection toggle above (`log_collect_debug`) is a *persistent, global* switch — safe only if an operator remembers to turn it off, and unsafe on a high-frequency endpoint like `/sync` (calls continuously, every connected client, every few seconds — an unbounded DEBUG-on window can fill the DB in seconds). War Room Mode is a **distinct, orthogonal mechanism**: a bounded, tagged, self-terminating diagnostic *session*, not a policy toggle. Exactly one may be active at a time (`war_room_sessions` table; `started_by`/`reason`/`scope`/`filter` JSONB/`max_entries`/`max_duration_s`/`ended_at`/`ended_reason`/`entries_collected`).

*Enforcement lives upstream of persistence, not inside the Writer's batch flush.* The obvious-looking design — "tag entries with `war_room_id` inside `Writer.flush_buffer/1`, right before the INSERT" — does not work, for two reasons: (1) `Writer` only ever sees entries `Handler.log/2` already decided to persist per the *ambient* policy, but AC4 requires war-room-matched entries to persist **regardless** of that policy (e.g. a DEBUG entry even when `log_collect_debug=false`); (2) `Writer`'s batching (every 5s or 100 entries) is far too coarse for single-entry budget granularity — a burst of matching entries inside one flush window would blow straight through `max_entries` before the batch is even inserted. Instead, `Nebu.Web.LogStore.WarRoom` (a new GenServer, sibling to `PolicyCache`) intercepts **inside `Handler.log/2`, before the `should_persist?` gate**: it holds the one cached active session, fast-paths to a no-op when none is active (a `persistent_term` flag, mirroring `PolicyCache`'s own "never block the hot path" design), and on a match performs one atomic `UPDATE ... entries_collected = entries_collected + 1[, ended_at = now(), ended_reason = 'budget_exhausted']`, serialized through the single GenServer — genuinely single-entry-granular, no read-then-write race, no batch-window overshoot.

*Two independent termination paths, both scoped to exactly one active session by construction* (AC2's "exactly one active" is enforced both app-level, in `Nebu.Admin.WarRoomManager`, and at the DB level via a partial unique index `war_room_sessions_single_active_idx ON ((1)) WHERE ended_at IS NULL` — the app check gives a friendly conflict message, the index is the real backstop against a race, and a `unique_violation` maps to the same `{:error, :conflict, ...}` tuple either way): (1) **budget exhaustion** — the atomic increment above; (2) **duration timeout** — a single `Process.send_after` scheduled on session load, checked against the *current* cached session id (so a stale timer message from a since-ended session is a no-op), re-scheduled with the *remaining* time on every load — including at app boot (`do_load_active/1`), which immediately ends an already-past-deadline session rather than silently leaving it active forever across a restart. This closes the exact "forgot to turn it off" failure mode that motivated bounding the feature in the first place.

*Scope/filter matching* (AC3/AC9): `scope` is `"all"`/`nil` (match everything) or an exact `route_template` string (e.g. `/_matrix/client/v3/sync` — verified the only sync route this codebase serves, no `r0`/`v1` alias exists, so exact-string matching is complete here); `filter` is an optional `{user_id, device_id}` JSONB map, AND-matched against the log entry's `metadata["user_id"]`/`["device_id"]`. Those two metadata fields did not exist anywhere in the logging pipeline before this story — `Nebu.Web.Plugs.RequestLogger` now also propagates them via `Logger.metadata/1`, extracted through a new `extract_user_id/1` helper that reduces `conn.assigns.current_user` to a bare identifier string regardless of route (Matrix routes: already a string; `/admin/*` routes, served by the SAME `RequestLogger` plug: `Nebu.Admin.Auth`'s `current_user` is a MAP containing an admin's email — `extract_user_id/1` exists specifically to never let that map, or its email, reach `Logger.metadata/1`; this was a security-review-driven fix after code-review caught the naive version leaking admin emails into `operational_logs` on admin routes).

*UI integration is a LiveView, not a new HTTP controller.* The story's own Dev Notes assumed a separate `war_room_controller.ex` with JSON-shaped endpoints (`POST /admin/war-room/start` → 409/session-id) — written before `admin-logs-monitoring-view` had shipped. In reality `/admin/logs` is `Nebu.Admin.LogsLive`, a LiveView, and the admin app's `:browser` pipeline is HTML-only with no JSON-API convention anywhere under `/admin`. The War Room panel (`Nebu.Admin.LogsLive.WarRoomPanel`) is therefore a component of that same LiveView: `handle_event("start_war_room"/"stop_war_room", ...)` calls straight into `Nebu.Admin.WarRoomManager` (the Admin-domain public API + inline SQL, ADR-018 — `start_session/1`, `stop_session/1`, `status/0`; no `Plug.Conn` awareness, directly unit-testable), gated by the same `on_mount :require_admin` as every other event in that LiveView. `WarRoomManager.start_session/1` also enforces `max_entries`/`max_duration_s` numeric bounds directly at this API boundary — added after a Kassandra security-review MEDIUM finding that the LiveView form's own client-side bounds check was the *only* place those bounds were enforced, insufficient defense-in-depth for a feature whose entire purpose is bounding runaway collection. A 2-second self-tick (independent of log traffic) refreshes the live "N/max entries · time remaining" status bar; the panel's outer wrapper carries `aria-live="polite"` (mirroring the retention-settings page's own established "stable wrapper, dynamic child" pattern) so screen-reader users get feedback on every start/stop/auto-terminate transition. `Nebu.Admin.LogsLive.mount/3` additionally accepts an optional `war_room_id` query param, seeding the initial log load from `Nebu.Web.LogStore.get_logs(%{war_room_id: id})` (its `@allowed_filter_keys` was extended to accept it — the SQL already selected the column, added by `operational-log-store`'s migration as a forward-looking seam) instead of the default unfiltered 200-row cap, giving a bookmarkable "show me everything tagged with this session" URL without reimplementing the stream component.

*Redaction is untouched — no new leak path.* `WarRoom.check/1` and the tagging it performs read/write only `route_template`, `metadata["user_id"/"device_id"]`, and `war_room_id` — it never touches `entry.message` or any payload content. The two-category redaction (`PayloadRedactor`, credentials + chat message content) still runs entirely upstream, inside `RequestLogger`'s `Logger.debug(fn -> ... end)` closure, before an entry ever reaches `Handler.log/2`; elevating collection via a war room changes *whether* an already-redacted entry gets persisted, never *what* is in it.

## War Room Indicator — Cross-Page Recording Status Visibility (Story `war-room-dedicated-page`)

**Problem:** When an operator starts a War Room session, the UI signals (recording indicator, countdown) were visible only on the page where the session was started (`/admin/logs` when embedded, later the dedicated `/admin/logs/war-room` page). An operator navigating away would lose real-time awareness that a recording session was active, and could inadvertently perform unmonitored diagnostic work or trigger a full page reload thinking the session had ended.

**Solution:** `Nebu.Admin.WarRoomIndicator` is a shared, stateless assign helper that every admin LiveView (DashboardLive, AuditLogLive, LogsLive, LogsLive.TraceMap, LogsLive.WarRoom) calls in its `mount/3` to poll `Nebu.Admin.WarRoomManager.status/0` every 2 seconds. Each page receives a live `@war_room_active` assign (boolean or session metadata), updated by a self-tick independent of user interaction. `Nebu.Admin.Layouts.live/1` consumes this assign to render:

- **Sidebar recording dot:** a pulsing red dot on the "War Room" nav item (children item under "Logs" group, populated by the admin-sidebar-nesting story) when `@war_room_active` is truthy.
- **Topbar recording pill:** a fixed-width pill showing `"War Room recording · mm:ss"` in the header, with the user who initiated the session and elapsed time, updated every second on the client via a lightweight JS hook (no server tick needed — the expiry state is already in `@war_room_active`'s `{started_at, max_duration_s}` tuple or similar).

This pattern is CSP-safe (no inline JS; the hook is registered in `app.js` like the nav-section toggle) and survives LiveView morphdom patches (the dot/pill are part of the shared Layouts chrome, not re-rendered on each view mount). An operator viewing any admin page sees a single source of truth for "is a recording active right now" without needing to navigate back to the War Room page — closing the situational-awareness gap the Trace Map Leitstand UX gate identified as a required closure for the feature to be production-safe.

## Temporary Capture — Time-Limited Per-Endpoint Diagnostic Collection (Story `trace-map-node-controls`)

**Rationale:** Long-polling endpoints (sync, keepalive, health) are rendered off-by-default in the Trace Map to keep the signal-to-noise ratio high — DEBUG/INFO collection is suppressed unless an operator explicitly enables temporary capture. This complements War Room Mode: where War Room is a global, bounded session with optional scope/filter, Temporary Capture is a **fine-grained, one-click per-endpoint toggle** for a fixed 5-minute window.

**Architecture:**

- **Storage:** `admin_temporary_captures` table (`endpoint TEXT PRIMARY KEY`, `enabled_at TIMESTAMP`, `expires_at TIMESTAMPTZ`, `started_by TEXT`) — a shared DB row is the single source of truth for timer state (cluster-safe, survives node restarts, deterministic server-time-based expiry).

- **Module:** `Nebu.Admin.TemporaryCaptureManager` (public API: `enable/2`, `disable/2`, `active?/1`, `cleanup_expired/0`; inline SQL, ADR-018). The 5-minute duration is configurable via `Application.get_env(:nebu, :temporary_capture_duration_s, 300)` for testing.

- **Cache:** `Nebu.Web.LogStore.CaptureCache` (persistent_term-backed, mirroring `PolicyCache` pattern). 2s polling refresh + on-demand invalidation (PubSub broadcast on capture enable/disable). Holds a map of `{endpoint → {enabled_at, expires_at}}` so should_persist?/2's enforcement avoids a per-request DB query on the hot path.

- **Enforcement in LogStore:** `Handler.log/2` invokes `should_persist?/2` *after* checking for ERROR (which always persists) and *after* the war-room check. `should_persist?/2` now consults `CaptureCache`: if a capture is active and not expired for the endpoint, persist the entry (DEBUG/INFO level) regardless of the global policy. Expired captures are cleaned up lazily on cache refresh.

- **UI:** The Trace Map inspector panel gains "Enable capture" button for off-list endpoints. On click, `Nebu.Admin.LogsLive.TraceMap.handle_event("enable_capture", ...)` → `TemporaryCaptureManager.enable/2` → PubSub broadcast → `CaptureCache` refresh. A countdown display (mm:ss, client-side computed from `expires_at`) updates every second; on expiry, the node reverts to off state. "Disable now" button calls `handle_event("disable_capture", ...)` → `disable/2` for early termination.

- **Audit trail:** Capture enable/disable are recorded as admin actions in `compliance_audit_log` (following the retention-settings pattern): `action: "enable_temporary_capture" / "disable_temporary_capture"`, `resource_type: "endpoint"`, `resource_id: endpoint_name`, `admin_user: current_user`, `timestamp: now()`.

- **Cascade for domain/nebu nodes:** Inspector selects allow per-endpoint level/retention changes and also cascade those changes to all satellite endpoints under a domain or nebu (batch `upsert_server_config` calls). Temporary capture is per-endpoint only; cascade does not apply to capture enable/disable (clicking an off node enables capture for that node alone, not its entire domain).

No new ADR: this is an operational feature layered atop the existing policy cache and handler pattern, not a new architectural decision.

## Trace Map Zoom/Pan — Client-Owned Viewport State (Story `trace-map-zoom-pan`)

**Interaction model:** the Trace Map Leitstand SVG supports Google-Maps-style navigation via four redundant input paths, each covering both zoom and pan:
- **Wheel** — cursor-centered zoom (the point under the cursor stays fixed), computed via `getScreenCTM().inverse()` against a real SVG point rather than raw pixel deltas, so it stays correct under the `viewBox`'s `preserveAspectRatio="xMidYMid meet"` letterboxing.
- **Drag** — click-and-drag pans the background; a `pointerdown` originating on a node (`[data-testid="trace-map-node"]`) sets a null guard for the whole gesture so a click (or even a large intentional drag) started on a node never pans and never blocks the node's own click handler.
- **Keyboard** — arrow keys pan (32px/press), `+`/`=`/PageUp and `-`/`_`/PageDown zoom, scoped to `event.target === mapSvg` so it never shadows the page's other keyboard interactions (node activation, the stream resizer). Keyboard/button zoom deliberately holds pan fixed (no re-centering) — only wheel zoom is cursor-centered by design.
- **Buttons** — a `trace-map-zoom-controls` group (zoom in/out/reset) and a `trace-map-pan-controls` group (up/down/left/right), both plain `<button type="button">` wired via `addEventListener` in the `TraceMapLeitstand` hook (`server/priv/static/assets/app.js`) — no `phx-click`, no inline handlers (CSP `script-src 'self'`). The pan buttons call the exact same `panByStep/2` the keyboard path uses, not a parallel implementation, so the two stay behaviorally identical by construction.

Zoom is bounded `1.0`–`4.0` (step `0.1`); pan is clamped so the viewport can never scroll past the map's edges at any zoom level. State does not persist across reload (by design) and lives only in the LiveView hook's JS-side instance state.

**Client-owned state survives LiveView patches:** this is the second feature in this epic to need this pattern, after the stream-resizer's height. Any client-set attribute the server never renders (the SVG's `viewBox`, here) is silently stripped by morphdom on the next patch, because the DOM node's identity is preserved but its non-server-tracked attributes are not. The hook's `updated()` callback reasserts the current `zoom`/`panX`/`panY` into the `viewBox` on every patch — the same fix shape as the resizer's `streamHeight` reassertion — rather than the server tracking viewport state as a socket assign (which would require a round-trip per zoom/pan input and defeat the point of client-side responsiveness).

**Accessibility:** the SVG root is `tabindex="0"` with an extended `aria-label` describing the keyboard controls, and carries an explicit `:focus-visible` CSS rule (`server/assets/css/app.css`) matching the existing node-ring/resizer focus-ring convention — a newly-focusable element needs its own explicit rule rather than relying on the browser's UA-default outline. Both zoom and pan have a dedicated on-screen button group specifically so a user who cannot perform a pointer drag, or whose assistive technology may not reliably enter "focus mode" for a bare `role="group"` container, still has a fully discoverable, keyboard-operable path to every viewport operation.

No new ADR: this is a client-side interaction enhancement to an existing visualization, not a new architectural component.

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

PII (email, display name, message content, credentials) must never appear in log output.

### Request/Response Payload Logging with Two-Category Redaction (Story matrix-payload-debug-logging, epic enhanced-logging)

When DEBUG logging is enabled (via `Logger.configure(level: :debug)` at runtime), the request logger captures and logs HTTP request/response bodies with mandatory two-category redaction (Story AC4–AC7):

**Category 1: Credentials and Secrets**
- Top-level fields: `password`, `new_password`, `access_token`, `refresh_token`, `client_secret`, `id_access_token`, `token` (OIDC token grant)
- HTTP headers: `Authorization` (entire header value)
- Nested recursively at any depth in the JSON tree
- Deprecated query-string pattern: `?access_token=<secret>` in URLs

All are replaced with the literal string `"***REDACTED***"`.

**Category 2: Chat Message Content**
- Any user-generated message text or metadata at any depth in the JSON tree — not just under a top-level `content` wrapper
- Includes Matrix event content fields: `body`, `formatted_body`, `topic`, `name`, `displayname`, `filename`, `reason` (k/b/redaction free text)
- Includes metadata inside `m.relates_to` (reaction emoji/key text), but NOT structural metadata fields like `rel_type`, `event_id`, `algorithm`, `sender_key`, `device_id`, `session_id`
- For write-path requests (Matrix `PUT .../send/{eventType}/{txnId}` and `PUT .../state/{eventType}[/{stateKey}]`), the event content is the raw top-level request body with no `content` wrapper — this is treated as user-generated content by default

All are replaced with `"***MESSAGE_CONTENT***"`.

**Implementation (Nebu.Web.Plugs.RequestLogger + Nebu.Web.Plugs.RequestLogger.PayloadRedactor):**

`Nebu.Web.Plugs.RequestLogger.call/2` logs every HTTP request at INFO level with method, path, status, duration_ms, and request_id. When DEBUG logging is enabled (checked via `Logger.level()`), a secondary `Logger.debug` call issues a JSON-structured log line with:
- All INFO-level fields
- `request_body` — the decoded JSON request map, redacted
- `response_body` — the decoded JSON response map, redacted
- `auth_header` — the redacted Authorization header value (if present)
- `query_string` — the redacted query string (if the request carried deprecated `?access_token=` patterns)

The redaction is performed by `Nebu.Web.Plugs.RequestLogger.PayloadRedactor.redact_payload/1` (pure, stateless, tested in isolation). The redactor walks the decoded JSON tree recursively, matches keys case-insensitively for credentials and at any depth for message-content fields (whether the field is under a `content` wrapper or at the root of a write-path body), and returns the redacted map. Redaction is idempotent.

**Failure handling:** If response-body JSON decoding fails (binary media, non-JSON Content-Type, or malformed JSON), the redacted response_body field is `nil` and the response is not logged verbatim.

**No toggle in this story:** The redaction layer itself is always enabled (it's a simple pass-through if DEBUG is off); no feature flag is required. Operators enable/disable DEBUG-level logging for the whole application via `Logger.configure(level: :debug)` at runtime without restarting the server.

### Query Logging Without Bound Parameters (Story matrix-payload-debug-logging, cycle 2 — Nebu.Repo.QueryTelemetry)

Ecto's default query logger outputs `:debug`-level log lines including the raw SQL text and bound parameter values. When an operator enables DEBUG logging to diagnose application issues, every database query leaks any credentials bound as SQL parameters (e.g., `SELECT * FROM matrix_sessions WHERE access_token = $1` prints the actual token value in `$1`).

**Solution:** Ecto's query logging is disabled globally (`config :nebu, Nebu.Repo, log: false` in `server/config/runtime.exs`, applied only when `NEBU_DB_URL` is set). Instead, Nebu hooks the underlying `:telemetry` event (which Ecto emits unconditionally regardless of the `log: false` setting) via `Nebu.Repo.QueryTelemetry`:

- `QueryTelemetry.attach/0` is called once from `Nebu.Application.start/2`, registering a handler on the `[:nebu, :repo, :query]` telemetry event.
- The handler logs a **sanitized summary at `:debug` level** — only `source` (the table name, when schema metadata is available; `"unknown"` for ADR-018 inline-SQL queries — itself safe information) and `duration_ms` (query execution time).
- Raw SQL text (`query` field) and bound parameter values (`params` field) are **never** logged.
- Success/failure is classified as `result=ok|error|unknown`, never surfacing the raw exception message.

This restores equivalent query-level debug visibility ("a query ran, how long it took") for **every query in the codebase** (present and future) without leaking any bound credentials. The handler is **disabled in `:test` environments** (via `config :nebu, Nebu.Repo.QueryTelemetry, enabled: false` in `server/config/test.exs`) to avoid cross-test log interleaving with `ExUnit.CaptureLog`.

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
  **Nested claim support (bugfix-nested-oidc-claim-support, 2026-07-01):** `admin_claim?/1`
  recursively searches the OIDC claims tree at arbitrary nesting depth for the configured marker
  value — not just flat top-level claims. This is required for **Keycloak**, whose role claims are
  nested (`realm_access: {roles: [...]}`, `resource_access: {<client>: {roles: [...]}}`), unlike
  Dex's flat `groups: [...]`. The Bootstrap Wizard's claim-picker (`extract_discovered_claims/1`)
  likewise flattens nested claims into dot-path-keyed options (e.g. `realm_access.roles`) so an
  operator can select them during setup. Backward compatible — flat claim configs are unaffected.
  **Path-scoped gate (story `scope-admin-claim-to-path`, epic `oidc-simplification`, 2026-07-02 —
  RESOLVES the any-key-scan risk above):** the Bootstrap Wizard now persists the selected claim's
  dot-PATH (`server_config.admin_group_claim_path`, e.g. `"realm_access.roles"` or a flat
  `"groups"`) alongside its value (`admin_group_claim`), via a new
  `Nebu.Web.OidcClaims.claim_at_path_matches?/3` (server/lib/nebu/web/oidc_claims.ex). When a path
  is configured, `admin_claim?/1` resolves ONLY that path and matches the marker there — a hit
  anywhere else in the claims tree (e.g. a self-editable `name`/`preferred_username` claim) no
  longer counts. This is an allowlist of the ONE path the operator themselves selected during
  bootstrap, not a claim-key denylist (a denylist was rejected during
  `bugfix-unify-admin-matrix-oidc-identity` code review as unsafe — it could silently break a
  legitimately-configured admin_group_claim). The path is now MANDATORY on every bootstrap
  completion — `bootstrap_confirm_claim/2` rejects a completion POST that omits a verified claim
  path (code-review MAJOR M1 fix during this story's own pipeline run) rather than silently
  persisting a path-less config, so a fresh instance can never end up on the fallback below.
  **Fallback (not a regression, pre-existing deployments only):** a deployment bootstrapped BEFORE
  this story shipped has no `admin_group_claim_path` in `server_config` and cannot acquire one
  retroactively (bootstrap runs exactly once) — for those, `admin_claim?/1` falls back to the
  pre-story any-key scan unchanged, logging at INFO level (no PII) so operators can see that a
  fresh re-bootstrap would harden the gate. Migration `000016_config_admin_group_claim_path` widens
  the `config_update_mutable` RLS policy so the key is runtime-mutable, mirroring
  `000013_config_oidc_scopes_mutable`'s pattern.
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
forced re-login roughly every 5 minutes against Keycloak.

**LiveView-idle session refresh (admin-liveview-session-refresh):** the silent refresh above is an HTTP
Plug, so it only re-runs on a genuine HTTP round-trip — an operator idling on an open LiveView
(Dashboard, AuditLog) with zero new HTTP requests would otherwise be force-logged-out at
`id_token.exp` regardless of `admin_oidc_refresh_mode`, since nothing on the persistent WebSocket
connection ever re-triggered `fetch_current_user/2`. Fixed with a client-side heartbeat rather than a
new server-side refresh path (Phoenix session cookies cannot be set over WebSocket anyway): a `phx-hook`
(`SessionKeepalive`, `server/priv/static/assets/app.js`) mounted in the shared LiveView layout
(`Nebu.Admin.Layouts.live/1`) polls a minimal `GET /admin/keepalive` endpoint every 60 s — well inside
the 120 s pre-expiry window — while any admin LiveView tab is open. The endpoint
(`Nebu.Admin.KeepaliveController`) sits behind the exact same `:browser` pipeline + `require_admin`
gate as every other admin route, returns a bare `204 No Content`, and introduces no business logic of
its own: simply reaching it means `fetch_current_user/2` already ran earlier in the pipeline and had
the chance to perform its existing silent refresh. Separately, `Nebu.Admin.Auth.on_mount/4` now treats
a session with an elapsed `session_exp` as refreshable (mount proceeds instead of forcing logout)
rather than calling the token endpoint itself — the socket handshake has no HTTP response to persist a
rotated refresh token into, so the actual token-endpoint exchange stays exclusively on the keepalive
HTTP path.

**Security hardening (Kassandra HIGH finding, 2026-07-01):** the initial version of this fix gated the
grace purely on the stored refresh token still being *decryptable* — but decryptability has no time
component (`Nebu.Web.SecretBox`/AES-256-GCM never expires a ciphertext), so a de-provisioned admin who
deliberately severed their own heartbeat (disabling JS, blocking `/admin/keepalive`, backgrounding the
tab) could keep an open Dashboard/AuditLog LiveView alive **indefinitely** across socket reconnects,
bypassing the only other server-side bound (`session_exp`). Fixed with an independent, non-bypassable
`refresh_grace_exp` timestamp (`session_exp + 180s`) written into the signed session cookie at login
and on every successful HTTP-path refresh — never on the socket path itself, so a severed heartbeat
cannot extend it. `on_mount/4`'s refreshability check now requires BOTH the refresh token decrypts
**and** `now <= refresh_grace_exp`; decryptability alone is necessary but no longer sufficient. A
healthy 60 s heartbeat keeps re-extending the bound well before it lapses (idle-tab UX preserved,
AC2), while a severed heartbeat now hard-expires the session within ~3 minutes of the last successful
refresh instead of never. See
`docs/stories/oidc-simplification/security-reports/admin-liveview-session-refresh-security-review-2026-07-01.md`
for the full finding and independent re-verification.

**Admin login provisions the Matrix identity (provision-matrix-identity-on-admin-login):** a
successful admin OIDC login (`Nebu.Admin.Auth.normal_callback/2` OR `bootstrap_confirm_claim/2`) now
provisions the SAME `users`-row the real Matrix `POST /_matrix/client/v3/login` path provisions, for
the SAME `matrix_user_id` the admin session carries (`Nebu.Matrix.UserId.from_claims/2` — single
source of truth for both flows). Previously an operator who only ever logged into the Admin UI (never
a Matrix client) had no `users` row at all and was invisible to `GET /admin/users`
(`Nebu.Admin.DB.list_users/3` reads exclusively from that table), even though their `matrix_user_id`
could already act via room writes (creator/actor attribution) after the prior story
`fix-bootstrap-admin-session-identity`.

The provisioning call is routed through a new `Nebu.Matrix.provision_identity/2` facade function
(ADR-020 — `Nebu.Admin` never calls `Nebu.Matrix.Session.TokenValidator` or `Nebu.Matrix.Profile.DB`
directly). Internally it performs the same `TokenValidator.validate/4` → `Profile.DB.upsert_profile/3`
pair the real Matrix `/login` path's `provision_and_respond/6` uses — idempotent (a re-provisioned
existing row is a no-op upsert, never an error) and nil-safe for the profile's `COALESCE` upsert (a
later Matrix login carrying no displayname claim never clobbers a displayname the user set
themselves).

**Architecture decision (AC2) — no auto-join for admin-only provisioning:** unlike the real Matrix
login path, `provision_identity/2` deliberately does **not** call
`Nebu.Matrix.EventDispatcher.Server.run_post_login_provisioning/2` (personal room + auto-join into
`is_auto_join` rooms/spaces). Rationale: an admin who authenticates once in the Admin UI is not
necessarily a communication participant, and unconditionally auto-joining them into every
`is_auto_join` room — some of which may hold confidential content — would be an unwanted (and, per
the story's security considerations, a potential information-disclosure) side effect of an
administrative action. Only the `users`-row + profile provisioning happens; auto-join remains
exclusive to the real Matrix client login flow. This is a recommendation, not a hard architectural
constraint — a future story may revisit it with an explicit, documented justification (see
`docs/stories/oidc-simplification/provision-matrix-identity-on-admin-login.md`, AC2).

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
