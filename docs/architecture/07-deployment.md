# 7 Deployment View

## Docker Compose Stack (Development + Production)

All builds run via Docker containers - no local Elixir or build-tool installation required.

```yaml
# Simplified docker-compose.yml topology
services:
  server:         # The single Elixir/OTP release (port 4000: health + Matrix C-S API incl.
                  #   /_matrix/media/v3/* + Admin UI /admin/*). This is the whole application.
  postgres:       # PostgreSQL 16 (port 5432)
  dex:            # OIDC provider for development (port 5556)
  minio:          # MinIO S3-compatible object store (port 9000: API; port 9001: console) - Story 12.1
  createbuckets:  # Init container: creates nebu-media bucket + nebu-app IAM user+policy - Story 12.1/12.3
  # gateway:      # REMOVED (ADR-021): the Go gateway is gone — the Elixir server IS the application.
  # media:        # REMOVED (ADR-021): the Go media gateway is gone — the server serves media in-process.
```

**One container, all surfaces (ADR-019/020/021):** There is no Go container. The single Elixir `server`
service serves the Matrix C-S API, the Matrix media API (`/_matrix/media/v3/*` and
`/_matrix/client/v1/media/*`), and the Admin UI (`/admin/*`) on the same Bandit port
4000. The Admin UI uses Phoenix HTTP controllers (PRG pattern) for CRUD pages and Phoenix LiveView for
real-time pages (Dashboard, AuditLog, Bootstrap Wizard). `server` is wired with the MinIO Docker secrets (`NEBU_MINIO_ACCESS_KEY_FILE` /
`NEBU_MINIO_SECRET_KEY_FILE`), the `NEBU_MINIO_*` env vars, and `depends_on` on `minio` (healthy) and
`createbuckets` (completed). ExAws config in `server/config/runtime.exs` reads the file-based MinIO
credentials. Media access control is a local `room_members` SQL call inside the app — no cross-process
hop.

**Admin login owned in Elixir:** The admin OIDC Authorization-Code + PKCE login lives in
`Nebu.Admin.Auth` (`/admin/login/start`, `/admin/callback`, `/admin/logout`). ADR-022: it uses the
**single** wizard-configured OIDC client (the same client that validates Matrix Bearer tokens); there is
no separate admin client and no `NEBU_ADMIN_OIDC_*` env. The `/admin/callback` redirect_uri is a fixed,
server-controlled target derived from `:server_name` + `:admin_session_secure`. The session is the signed
Phoenix `secret_key_base` cookie (http_only, secure, SameSite=Lax), capped at min(idToken.exp, now+8h).

## OIDC Configuration Sourcing (ADR-022 — Bootstrap-Only)

**OIDC is configured EXCLUSIVELY through the Bootstrap Wizard, persisted in `server_config`.** There are
no `NEBU_OIDC_*` / `NEBU_ADMIN_OIDC_*` configuration environment variables. The server boots without OIDC
config and fails closed (config validated per-operation, not at boot): before bootstrap every Bearer token
is rejected `401 M_UNKNOWN_TOKEN` and the admin UI redirects to `/bootstrap`. A **single** OIDC client
serves both Matrix Bearer validation and admin operator login.

| Scenario | Source of truth | Behavior |
|---|---|---|
| First-boot (pre-bootstrap) | none | Server boots; all Bearer tokens 401; admin → `/bootstrap`. |
| Bootstrap wizard step 2 | operator input → `server_config` | Collects issuer, the single client id/secret, audience, JWKS URI (all required). Completion promotes `bootstrap_draft` → `server_config`; `OidcConfig`/`JwksCache` caches refresh; `:pg` invalidates peer nodes. |
| Post-bootstrap | `server_config` (via `OidcConfig` cache) | OidcPlug / SsoLogin / Admin.Auth / MSC2965 discovery resolve issuer/audience/JWKS-URI/client from the cache. |

**Component: `Nebu.Web.OidcConfig`** — to avoid a per-request DB lookup on the OIDC hot path, config from
`server_config` is cached in the named ETS table `:nebu_http_oidc_config` (read_concurrency: true). The
GenServer loads on boot from `server_config` (`oidc_issuer`, `oidc_audience`, `oidc_jwks_uri`), refreshes
on wizard completion (`OidcConfig.refresh/0`), is cluster-aware via `:pg` (ADR-020, M-3), and returns
`nil` for any unset key.

**Resolution logic (ADR-022 — server_config only, fail-closed):**

```
issuer / audience (OidcPlug, SsoLogin, Admin.Auth, discovery):
  OidcConfig.get() → ETS cache (may be nil) → if nil, fail closed (401 / 503 / redirect)

JWKS URI (JwksCache):
  OidcConfig.jwks_uri() → ETS cache → if nil, auto-discover from issuer's
    /.well-known/openid-configuration → if still nil, no keys → all tokens rejected

single client id/secret (SsoLogin, Admin.Auth):
  server_config.oidc_client_id + AES-256-GCM-decrypted oidc_client_secret → if unset, fail closed
```

**Bootstrap Wizard form (ADR-022):** Step 2 collects `oidc_issuer`, `oidc_client_id`,
`oidc_client_secret`, `oidc_audience`, and `oidc_jwks_uri`. All fields are **always editable and
required** — there is no env-lock/`disabled` mode (the former env-locked-fields behavior is removed).
The client secret is stored AES-256-GCM encrypted at rest.

On step 3 (finalization), the wizard persists all collected values (including `oidc_audience` and
`oidc_jwks_uri`) into `server_config` atomically. It then calls `OidcConfig.refresh/0` to invalidate
the ETS cache and trigger cluster-wide reloads.

**Security notes:**

- **Fail-closed on missing config:** If bootstrap completes without an audience or JWKS URI (when env vars
  are also absent), the OIDC plug correctly enters a fail-closed state and rejects all tokens with 401.
  The Bootstrap Wizard validates this at form submission (AC2, AC5) to prevent completing into a broken state.
- **Env vars override DB:** When `NEBU_OIDC_*` env vars are set, they always take precedence over the
  `server_config` values. This ensures that operators can lock OIDC config at deployment time and prevent
  accidental misconfiguration via the Bootstrap Wizard.
- **Cluster coherency:** All nodes in a cluster refresh their ETS caches within milliseconds after a wizard
  completion, ensuring consistent OIDC enforcement across the cluster.

**Port map:**

| Service | External Port | Purpose |
|---|---|---|
| Elixir application (`server`) | 4000 | Matrix C-S API + `/_matrix/media/v3/*` + Admin UI `/admin/*` + health/info |
| Elixir application (`server`) | 9000 | Vestigial gRPC listener (nothing dials it; amended ADR-005) — internal network only |
| PostgreSQL | 5432 | Database (internal Docker network only) |
| Dex (dev) | 5556 | OIDC provider (development only) |
| MinIO S3 API | 9000 | Object storage API (S3-compatible) - local dev only |
| MinIO Console | 9001 | Object storage management UI - local dev only |

## OAuth 2.0 Authorization Server Configuration (ADR-033 — Broker Model, Stories oauth-metadata-dcr-admin-approval, oauth-authorize-idp-delegation-code, oauth-token-endpoint, oauth-token-revocation-logout, oauth-legacy-coexistence, oauth-account-management, oauth-hardening-hygiene)

Nebu can act as an OAuth 2.0 authorization server (broker model) in front of the corporate OIDC provider. This feature is **disabled by default** (`oauth_enabled = false`) and must be explicitly enabled in `server_config`: with the checkbox of the Admin UI (**Configuration**, section "OAuth 2.0 authorization server", `/admin/config`, story admin-oauth-switch) or with SQL (see "Activating OAuth" and "The Admin UI switch").

**New server_config keys** (bootstrap/admin-configurable, added by migration 000040; the last two rows added to the allowlist by migration 000042):

| Key | Type | Default | Purpose |
|---|---|---|---|
| `oauth_enabled` | boolean | `false` | Master switch: when `false`, register, authorize, token, JWKS, openid-configuration and `/account` answer `404` (`M_UNRECOGNIZED`, without an `error` member on token/JWKS/openid-configuration); `/oauth2/revoke`, `/logout` and `/logout/all` stay live and OAuth access tokens keep working until they expire. When `true`, Nebu advertises itself as an OAuth 2.0 authorization server. **Trusted-proxy client-IP resolution is implemented (`NEBU_TRUSTED_PROXY_CIDRS`); the operator verifies it before activation (gate item 1).** A change (Admin UI checkbox or SQL) takes effect on every node within `NEBU_OAUTH_CONFIG_CACHE_MS` (default 2 s); the saving node answers at once. |
| `oauth_issuer_url` | string | `nil` | Public HTTPS URL of Nebu itself (used as the `issuer` in RFC 8414 metadata). Must be https and match the host clients reach Nebu on. Validated at read time (and by the Admin UI form with the same function); missing value makes metadata/discovery endpoints answer `404 M_UNRECOGNIZED`. |
| `oauth_pending_ttl_days` | integer | `30` | TTL in days for `pending` registrations (cron purge via Oban worker). Approved and rejected registrations are never purged. |
| `oauth_pending_cap` | integer | `5000` | Maximum number of `pending` registrations globally. New registrations above this cap are refused with `503 temporarily_unavailable`; dedup hits (known metadata hash) bypass the cap. |
| `oauth_pending_host_cap` | integer | `20` | Maximum number of `pending` registrations per (registrable domain of the `client_uri` host, client source); the source is the resolved client IP (`NEBU_TRUSTED_PROXY_CIDRS`), IPv6 per /64. A source is also limited to 100 pending registrations over all domains (built-in). Same response as the global cap. A `client_uri` host that is a public suffix (`github.io`, `co.uk`) is refused at registration. |
| `oauth_access_token_ttl_seconds` | integer | `900` | Access-token lifetime of OAuth sessions (story oauth-token-endpoint, migration 000042 allowlist). Valid 60..3600; absent/invalid/unreadable => 900. Not a session maximum: that stays `NEBU_MATRIX_SESSION_TTL_SECONDS` (copied into `session_expires_at`, never extended). |
| `oauth_idp_revalidation` | string | `per_refresh` | `per_refresh`: every Nebu refresh redeems the stored IdP refresh token (a user disabled at the IdP loses the session at the next refresh). `off`: only `users.is_active` is re-checked. Unknown values behave as `per_refresh` (fail safe). Requires `matrix_oidc_refresh_mode=offline` (IdP refresh token) when `per_refresh`. Operator note: switching `off` -> `per_refresh` revokes OAuth sessions without an IdP refresh token at their next refresh (follow-up q). |

**Environment variable `NEBU_OAUTH_CONFIG_CACHE_MS`** (story oauth-hardening-hygiene, HY1; read in `config/runtime.exs`): per-node TTL cache of the switch state (`oauth_enabled`, `oauth_issuer_url`) in milliseconds, integer `0..5000`, default `2000`, `0` = off (every request reads `server_config`); absent, junk or out of range = 2000. An operator write takes effect on every node within this time (bounded staleness, ADR-020 note HY2); only successful reads are cached, an unreadable `server_config` is never cached (fail closed as before). Scripts that flip the switch and probe at once must wait or poll `GET /_matrix/client/v1/auth_metadata` (the e2e fixtures do).

**Environment variable `NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME`** (story oauth-client-revocation, SO5; read in `config/runtime.exs`, only the exact value `true` switches it on): approving or revoking an OAuth client in the admin UI requires a fresh sign-in at the IdP (`/admin/login/start?mode=reauth`: `prompt=login`, `max_age=0`, and an `auth_time` claim at least as recent as the start of that flow). An IdP that reports no `auth_time` cannot prove it, so the **default is off (fail closed)**: such an admin cannot approve or revoke in the UI (revoking stays possible through `bin/nebu rpc`, see "Revoking a client"). Set the variable to `true` ONLY where the IdP has no SSO session of its own, so that a completed login flow is an interactive login (the dev Dex of `docker-compose.yml` does this: the root `docker-compose.yml` is a DEV file and its setting of this variable must never be copied into a production deployment). **Risk:** with the opt-out an IdP that silently reuses an SSO session makes the re-authentication prove nothing. The deploy templates do not set it.

**Behavior while oauth_enabled = false:**
- `GET /_matrix/client/versions` → v1.1-v1.11 (today's body), `GET /login` without the OAuth-aware flags
- `GET /_matrix/client/v1/auth_metadata` → `404 M_UNRECOGNIZED`
- `POST /oauth2/register` → `404 M_UNRECOGNIZED`
- `/account` and every `/account/*` path → `404` HTML page `unavailable` (story oauth-account-management, A3: same predicate as `auth_metadata`; an unreadable config answers `503` + `Retry-After: 5`; no rate-limit token and no DB access beyond the config read)
- `GET /_matrix/client/v1/auth_issuer` → IdP passthrough (legacy OIDC discovery)
- `GET /_matrix/client/unstable/org.matrix.msc2965/auth_metadata` → IdP passthrough
- `POST /oauth2/revoke` is **still served** (story oauth-token-revocation-logout, R13: it is exempt from the T22 kill switch because it can only delete; otherwise server sessions would survive a logout made while OAuth is off). Only an unreadable config (`:unknown`) answers `503 {}` + `Retry-After: 5`. Operator note: switching OAuth off does not end existing OAuth sessions (they keep working through the opaque-token path); `POST /oauth2/revoke`, `POST /logout` and `POST /logout/all` still end them.

**Behavior while oauth_enabled = true:**
- `GET /_matrix/client/versions` lists `v1.1` ... `v1.15` (story oauth-versions-switch; while `oauth_enabled = false`, or with an invalid issuer / unreadable config, it lists v1.1-v1.11; `Cache-Control: no-store`, independent of authentication) and the `m.login.sso` flow of `GET /login` carries `oauth_aware_preferred`; the SSO `action` parameter is honoured
- All three discovery paths serve Nebu's own OAuth metadata (RFC 8414 document with issuer = oauth_issuer_url)
- DCR endpoint accepts registrations (pending approval)
- Admin approves/rejects registrations via the `/admin/oauth/registrations` UI page (approve: a confirm page, a fresh admin re-authentication and strict fetch metadata; story oauth-client-revocation); approved clients are listed under `/admin/oauth/clients` and can be revoked there (`/admin/oauth/clients/revoked` lists the revoked ones)
- The account-management page (`GET /account`, `/account/reauth`, `POST /account/devices/delete`, `/account/cross_signing_reset/approve|decline`, `/account/logout`) is served; `auth_metadata` carries `account_management_uri` (`<issuer>/account`) and `account_management_actions_supported`; browser POSTs are CSRF-protected and answer 303; no CORS
- `POST /oauth2/token`, `GET /oauth2/jwks` and `GET /.well-known/openid-configuration` are served (and answer `404 {"errcode":"M_UNRECOGNIZED"}` without an `error` member while disabled; an unreadable config answers `503 {}` + `Retry-After: 5`); `POST /oauth2/revoke` (RFC 7009, story 4) is served in every state except an unreadable config (see above), so every endpoint advertised in the metadata exists

**Migration 000040:** `oauth_clients_and_auth_metadata` creates the `oauth_clients` table (client_id, metadata JSONB, metadata_hash, status, approved_by, approved_at, rejected_by, rejected_at, created_from_ip, user_agent, created_at, last_used_at) with RLS guards and database-enforced lifecycle invariants (via trigger: decisions are final, pending insertions only, required fields). Also creates `oauth_pending_purge` Oban worker (hourly, queue oauth_cleanup) and adds the four new config keys to `config_update_mutable` allowlist.

**Migration 000041 (story oauth-authorize-idp-delegation-code):** `oauth_authz_requests_and_codes` creates two tables for the authorization code flow, both `ENABLE` + `FORCE ROW LEVEL SECURITY` with grants to the runtime role `nebu_app`:
- `oauth_authz_requests` (PK `state_hash`; `client_id` FK to `oauth_clients` ON DELETE CASCADE, `redirect_uri`, `code_challenge`, `device_id`, `scope`, `scope_prefix`, `response_mode`, `client_state`, `client_nonce`, `openid_requested`, `idp_code_verifier_enc` (SecretBox), `idp_nonce`, `browser_binding_hash`, `created_at`, `expires_at` <= created_at + 10 min). Grants SELECT/INSERT/DELETE only (no UPDATE; rows are consumed by DELETE).
- `oauth_codes` (PK `code_hash`; `client_id` FK, `redirect_uri`, `code_challenge`, `device_id`, `user_id`, `scope`, `scope_prefix`, `response_mode`, `client_nonce`, `openid_requested`, `idp_rt_enc` (SecretBox), `auth_time`, `created_at`, `expires_at` <= created_at + 60 s, `used_at`). Grants SELECT/INSERT/UPDATE/DELETE; INSERT policy requires `used_at IS NULL`, DELETE policy only rows expired > 24 h; trigger `oauth_codes_guard` allows only `used_at` NULL -> NOT NULL.
- CHECKs on `scope_prefix` (the two Matrix prefixes) and `response_mode` (`query`/`fragment`); indexes on `expires_at`. No new `server_config` keys; `oauth_enabled` stays off by default.

**Migration 000042 (story oauth-token-endpoint):** `oauth_sessions_and_signing_keys` (new files; 000040/000041 untouched):
- `matrix_sessions` gains `auth_api TEXT NOT NULL DEFAULT 'legacy'` (`legacy` | `oauth`; the DEFAULT keeps existing rows and not-yet-upgraded nodes valid during a rolling deploy), `client_id` (FK to `oauth_clients`, `ON DELETE RESTRICT`: a registration with a session cannot be deleted), `scope`, `session_expires_at` (absolute session maximum) and `oauth_code_hash` (the code the session derives from, for reuse revocation). Named CHECKs `matrix_sessions_auth_api_check` and `matrix_sessions_oauth_shape_check` (legacy rows carry none of the OAuth columns; OAuth rows need client, scope, `session_expires_at` and `expires_at <= session_expires_at`). Indexes `idx_matrix_sessions_user_device`, `idx_matrix_sessions_oauth_code_hash` (partial) and `idx_matrix_sessions_client_id` (partial). The CHECK/FK validation takes short locks while it scans `matrix_sessions`. No RLS change (the table has none).
- `oauth_signing_keys` (PK `kid` = RFC 7638 thumbprint; `alg` CHECK `ES256`, `public_jwk` JSONB, `private_jwk_enc` = SecretBox ciphertext, `status` `active`|`next`|`retired` (`next` = a pre-published key, migration 000047), `created_at`, `retired_at`, `not_after`), `ENABLE` + `FORCE ROW LEVEL SECURITY`, grants SELECT/INSERT/UPDATE to `nebu_app` (no DELETE, no DELETE policy). Partial UNIQUE indexes `oauth_signing_keys_one_active` (at most one active key) and `oauth_signing_keys_one_next` (at most one next key, 000047); INSERT policy admits only a fresh active or next row; a `next` key may become active only 900 s after it was created (the database enforces the 900 s promotion rule, 000047); trigger `oauth_signing_keys_guard` makes key material immutable, forbids `retired -> active` and only allows `not_after` to be set/raised.
- `server_config` allowlist: policy `config_update_mutable` is re-created with 000040's key list verbatim plus `oauth_access_token_ttl_seconds` and `oauth_idp_revalidation` (no values inserted; absent keys use the defaults). `.down.sql` restores 000040's policy text, drops the table/trigger function, deletes `auth_api = 'oauth'` rows and drops the columns.
- No new Oban worker: rotated-away rows and expired OAuth sessions are removed by the existing `cleanup_expired/0` (`COALESCE(session_expires_at, expires_at)`); a per-device row cap is follow-up (o).

**Migration 000043 (story oauth-account-management):** `oauth_account_management` (new files; 000040-000042 untouched, `.down.sql` drops exactly what `.up.sql` creates):
- `oauth_account_login_requests` (PK `state_hash` SHA-256 hex; `idp_verifier_enc` SecretBox, `idp_nonce`, `binding_hash`, `return_action` NULL = default page or one of the five actions (CHECK), `return_device_id`, `replaces_session_hash`, `created_at`, `expires_at` <= created_at + 10 min (CHECK)). Grants to `nebu_app`: `SELECT, INSERT, DELETE` only (rows are never updated; the migration also `REVOKE`s UPDATE because `dev/postgres/init/01-roles.sql` grants every privilege on new tables by default).
- `oauth_account_sessions` (PK `session_hash` SHA-256 hex of a 256-bit cookie value; `user_id`, `auth_time` unix seconds, `csrf_hash`, `created_at`, `last_seen_at`, `idle_expires_at` <= `expires_at` (CHECK), `expires_at` <= created_at + 1 hour (CHECK)). Grants `SELECT, INSERT, UPDATE, DELETE`.
- Both tables `ENABLE` + `FORCE ROW LEVEL SECURITY` with open policies per granted command (the 000041 pattern; the table owner would otherwise bypass RLS in the single-role dev setup); expiry indexes for the purge.
- Index `uia_sessions_user_op_pending_idx ON uia_sessions (user_id, op) WHERE consumed = FALSE` (per-user listing of pending `cross_signing_reset` requests).
- No `server_config` key (the `config_update_mutable` policy is unchanged); lifetimes are code constants (idle 900 s, absolute 3600 s, fresh window 300 s). The account page needs no new environment variable.

**Migration 000045 (story oauth-authorize-freshness):** `oauth_consent_and_refresh_leases` (new files; 000040-000044 untouched, `.down.sql` drops the tables, deletes the sessions with a NULL `auth_time` and restores NOT NULL):
- `oauth_consent_requests` (PK `binding_hash` SHA-256 hex of the 256-bit consent cookie; `client_id` FK ON DELETE CASCADE, the inputs of the authorization code, `idp_rt_enc` SecretBox, `auth_time` TIMESTAMPTZ NULL (the raw claim or NULL), `login_fresh`, `created_at`, `expires_at` <= created_at + 5 min (CHECK)). Grants `SELECT, INSERT, DELETE` only (rows are consumed by DELETE; UPDATE is revoked like in 000043), index on `expires_at`. Soft cap of 10 000 live rows inside the INSERT.
- `oauth_idp_refresh_leases` (PK `(user_id, device_id)`, FK to `devices` ON DELETE CASCADE, `holder`, `acquired_at`, `lease_until` <= acquired_at + 120 s (CHECK)). Grants `SELECT, INSERT, UPDATE, DELETE`. The per-device lease that serializes the IdP leg of a `per_refresh` refresh (TTL 60 s; a killed node leaves its lease until then: followers get `503` + `Retry-After: 2`); no advisory lock, no transaction across the IdP call.
- `oauth_consent_requests` also carries `source_key` (SourceKey, per-source cap 20) with the per-user cap 5 and the global 10 000 inside the INSERT; `oauth_codes` gains `device_holder_checked` / `device_holder_client_id` (the device holder the user accepted at Allow, re-checked at the token exchange under the devices row lock).
- Rolling deploy note: a browser that a NEW node sent to `/oauth2/consent` and that lands on an OLD node gets `404` (no route) until every node is upgraded; cut all nodes over before `oauth_enabled`.
- `oauth_account_sessions.auth_time` nullable (000045): an IdP that reports no `auth_time` gives a session that is never fresh.
- Both new tables `ENABLE` + `FORCE ROW LEVEL SECURITY` with open policies per granted command; no `server_config` key. Additive: nodes that still run the previous release keep working during a rolling deploy (they simply do not show the consent page until they are upgraded).

**Migration 000046 (story oauth-client-revocation):** `oauth_client_revocation` (new files; 000040-000045 untouched, `.down.sql` restores 000040's CHECKs, insert policy and guard function verbatim and REFUSES while a `revoked` row exists, so it can never turn revoked into approved):
- `oauth_clients` gains `revoked_by`, `revoked_at`, `revoked_reason` (<= 500 characters, only on a revoked row); the status CHECK admits `revoked`; the decision CHECK is re-created (a revoked row keeps its `approved_*` attribution).
- The guard trigger function allows exactly ONE new transition, `approved -> revoked` (`revoked_by` / `revoked_at` set, the approval untouched); every other change of a decided row, `pending -> revoked` and `rejected -> revoked` included, stays a `check_violation`. A revoked row is never deleted (the pending-only DELETE policy is unchanged): it keeps its metadata hash occupied, so identical metadata is never pending or approved again. The INSERT policy additionally requires `revoked_* IS NULL`. No `server_config` key, no change of `config_update_mutable`.
- Additive: nodes that still run the previous release keep working; they simply do not know the `revoked` status until they are upgraded (they refuse every status but `approved` at token and authorize).

**Migration 000047 (story oauth-hardening-hygiene):** `oauth_signing_key_next` (new files; 000040-000046 untouched): `oauth_signing_keys.status` admits `next` (CHECKs re-created), partial UNIQUE index `oauth_signing_keys_one_next`, the INSERT policy admits `active` and `next`, and the guard trigger function keeps every 000042 rule and adds `active -> next` / `retired -> next` forbidden, `next -> active` only for a row at least 900 s old and `next -> retired` needs `retired_at`. The `.down.sql` DELETES a published `next` key (a half-finished rotation is lost), restores 000042's CHECKs, policy and guard function and drops the index; because FORCE RLS binds the table owner and there is no DELETE policy it runs the DELETE between `NO FORCE` / `FORCE ROW LEVEL SECURITY`. Additive: nodes still on the previous release never read a `next` row as active.

**Reverse proxy (follow-up m, gate before `oauth_enabled`):** the reference nginx templates (`deploy/tofu/examples/{stackit,upcloud}/cloud-init.tftpl`) proxy only `/_matrix/`, `/.well-known/matrix/`, `/admin/` and `/api/v1/` to the server; Element Web is served at `/`. `/oauth2/` and `/.well-known/openid-configuration` must be routed to the server before OAuth can be enabled, otherwise the token endpoint, the JWKS and the discovery document are unreachable. `/oauth2/revoke` falls under the same gap (Element Web logout would otherwise hit the SPA, not the server). Behind nginx the per-IP buckets (`oauth_token`, `oauth_token_refresh`, `oauth_jwks`, `oauth_revoke` 60/min burst 600, Element sends two revocations per logout) are keyed on the client address the templates hand to Nebu (gate item 1 and story P5; see "Client IP behind a reverse proxy"); an unverified or TCP-mode LB leaves them shared on one peer address. The issuer URL must have an empty path (`OidcTokenRefresher` resolves `.well-known/openid-configuration` relative to it). **Extended by story oauth-account-management (A2):** `/account` and every `/account/*` sub-path must be routed to the server in both cloud-init templates as well (location `/account` and `/account/`), otherwise the account page (device sign-out, cross-signing reset approval, the `m.oauth` URL) lands in the Element Web SPA. **Closed by story P5 (deploy templates, verify after deploy):** both cloud-init templates now route `/oauth2/`, `= /account`, `/account/` and `= /.well-known/openid-configuration` (plus `/.well-known/matrix/`) to the server whenever Element Web is enabled (`enable_element_web`; without it the catch-all `location /` already forwards everything to the server) behind the nginx proxy (`acme`, `alb`, UpCloud `dynamic`), and log without query strings (see "Reverse proxy" below).

**Account page cookies and the `X-Forwarded-Proto` requirement (story oauth-account-management, A6/A8):**
- Session cookie: `__Host-nebu_account` (`Path=/; Secure; HttpOnly; SameSite=Lax`, https requests, the only name read on https: no sibling-subdomain cookie tossing, follow-up j); on plain http (dev / test only) `nebu_account` (`Path=/account; HttpOnly; SameSite=Lax`). Per-flow binding cookies (story oauth-hardening-hygiene, HY9): on https `__Host-nebu_acct_<16 hex>` (account login) and `__Host-nebu_oa_<16 hex>` (authorize; the 16 hex are the start of the state hash), both `Path=/; Secure; HttpOnly; SameSite=Lax; Max-Age=600`, no `Domain`, and ONLY that name is read on https (no fallback to the legacy name; a flow in flight across the deploy or a scheme mismatch ends in `400 invalid_state`: the user starts again); on plain http (dev / test) `nebu_acct_<16 hex>` / `nebu_oa_<16 hex>` with `Path` = the shared callback path and no `Secure`. `SameSite=Lax`, not `Strict`: the cookie is set on a callback reached through a cross-site redirect chain.
- A request counts as https when `conn.scheme == :https` OR the FIRST `X-Forwarded-Proto` value is `https` (`Nebu.Web.RequestScheme`, the same helper as the SSO callback URL and `.well-known`). A TLS-terminating proxy MUST therefore forward `X-Forwarded-Proto`; otherwise Nebu sets the non-Secure, non-`__Host-` cookies: the `nebu_account` session cookie (`Path=/account`), the consent cookie and both binding cookies (`nebu_oa_`, `nebu_acct_`) (operator note HY15, follow-up ah; `Path=/` of the `__Host-` cookies sends the one-time binding value with every request to the host for at most 10 minutes, accepted: L-2; verify in the browser devtools that an https login shows the `__Host-` names).
- The pages send `Referrer-Policy: same-origin`, `Cache-Control: no-store`, `X-Frame-Options: DENY` and a strict CSP; they must not be cached or framed by the proxy. The `{"oauth_account", ip}` bucket (600/h) is keyed per client address (`Nebu.Web.ClientIP.get/1`); behind nginx that is the real client only when `NEBU_TRUSTED_PROXY_CIDRS` lists the proxy (see "Client IP behind a reverse proxy" below), otherwise all browsers share one bucket.

**Story oauth-token-revocation-logout:** no migration (000042 untouched; the token lookup uses the existing hash indexes, the teardown lock the `devices` primary key), no new `server_config` key, no new Oban worker. Operator notes: `POST /logout/all` needs no UIA (an access token alone deletes all devices and keys of the user; cross-signing keys stay); GDPR key erasure now ends the user's sessions after its commit but does not deactivate the user, so deactivate before erasing.

**Flow-state housekeeping (story oauth-authorize-idp-delegation-code):**
- Purge worker: `Nebu.Workers.OAuthFlowPurgeWorker` runs every 10 minutes (Oban cron `*/10 * * * *`, queue `oauth_cleanup`, `max_attempts: 3`); deletes `oauth_authz_requests` and `oauth_consent_requests` (story oauth-authorize-freshness) past `expires_at` and `oauth_codes` 24 h after `expires_at` (batched 1000 rows, max 20 batches per table and run). Correctness never depends on it (consume checks `expires_at`). Since story oauth-account-management (A23) it also deletes expired `oauth_account_login_requests` and `oauth_account_sessions` (`Nebu.OAuth.purge_expired_account_state/0`, same batching) and expired `uia_sessions` rows (`Nebu.Matrix.purge_expired_uia_sessions/0`, which schedules the so far unused `Uia.cleanup_expired/0`; expired rows only).

**Pending registration housekeeping:**
- Purge worker: `Nebu.Workers.OAuthPendingPurgeWorker` runs hourly (Oban cron, queue `oauth_cleanup`, limit 1)
- Purge query: `DELETE ... WHERE status = 'pending' AND created_at < now() - interval 'N days'` (batched 1000 rows max)
- Database guard (RLS): the runtime role can only delete rows where `status = 'pending'` (UPDATE→approval/rejection is final)

## Activating OAuth (`oauth_enabled`): preconditions, checklist, rollback

Story `oauth-versions-switch` (story 9, the last story of epic `oauth-broker`, ADR-033 section "`/versions` switch and activation (story 9)") adds the `/versions` switch and this checklist. **Nothing in the epic enables OAuth**: `oauth_enabled` stays `false` until every gate below is closed. With the switch off the OAuth surface is dormant and `GET /_matrix/client/versions` answers today's v1.1-v1.11 body. The `/versions` code path itself runs in EVERY deployment (it reads `server_config` once per request, bounded to 500 ms with a throttled warning and a fail-closed v1.11 answer; the per-node TTL cache of the switch state, `NEBU_OAUTH_CONFIG_CACHE_MS`, serves most of them without a read, HY1), so it is not "dormant" in the sense of not executing.

**What the switch does (one predicate).** While `oauth_enabled = true` AND `oauth_issuer_url` is a valid https issuer (the `auth_metadata` 200 predicate, `Nebu.OAuth.oauth_aware?/0`, evaluated per request on top of the per-node cache, so a change shows within `NEBU_OAUTH_CONFIG_CACHE_MS` (default 2 s) on every node): `GET /_matrix/client/versions` lists `v1.1` ... `v1.15`, `auth_metadata` / the unstable alias / `/.well-known/openid-configuration` answer 200, `GET /login` carries `oauth_aware_preferred`, the SSO `action` is honoured, `/oauth2/*` and `/account*` are served. Otherwise (disabled, invalid issuer, unreadable `server_config`) every one of them answers its documented disabled answer and `/versions` lists v1.1-v1.11 (never a 5xx: the load balancers health-check it).

### The Admin UI switch (story admin-oauth-switch)

Instances without a convenient database console (UpCloud, Stackit) switch OAuth on and off on the **Configuration** page of the Admin UI (`/admin/config`, section "OAuth 2.0 authorization server"; ADR-033 "Admin UI switch", AS1-AS12). The section has the checkbox "Offer the OAuth 2.0 API" (`oauth_enabled`; unchecked = off = the kill switch), the field "Issuer URL" (`oauth_issuer_url`), the checkbox "I have read the activation checklist ..." and the button "Save OAuth settings". Everything else in this checklist still applies: the checkbox does not replace the preconditions and the manual verification below, it is only the way to flip.

- **Issuer.** Validated with the function the server uses at runtime (https only, a host, no userinfo, no query, no fragment, an empty path; a trailing `/` is stripped; the form adds: no spaces or control characters, at most 255 characters). Switching on without a valid issuer is refused with a message; an invalid issuer is refused also while off (a junk value is never stored). While nothing is stored the field suggests `https://<NEBU_SERVER_NAME>` (secure admin session, not `localhost`) and says that the value is suggested, not saved yet. A wrong but valid issuer is served as written (check it: `curl <issuer>/_matrix/client/v1/auth_metadata`); an invalid stored issuer keeps OAuth off (fail closed).
- **Protection (the same as the SSO trust lists).** Admin role (`require_admin`), the Phoenix CSRF token, strict fetch metadata (WebKit: the hidden `_click_proof` field, a notice page instead of a 403), a **fresh sign-in** (marker bound to `/admin/config`, 5 minutes, consumed by a successful save: the form shows "Sign in again to save" until you have signed in, then "Save OAuth settings"), no framing, `Cache-Control: no-store`. BOTH directions are protected, also switching off: a script on the shared origin (SO7) that switches OAuth off is an availability attack on every OAuth client. The SQL rollback below stays the emergency path when the IdP is down.
- **Acknowledgement.** Switching on, or setting / changing a non-empty issuer (also while OAuth stays off: the origin of the issuer is trusted by the legacy SSO login without a confirmation page, independent of `oauth_enabled`), needs the checkbox "I have read the activation checklist ..."; switching off with the issuer unchanged, and clearing the issuer, need none.
- **Audit.** One `audit_log` row `oauth_switch_changed` per change (actor, `enabled_before` / `enabled_after`, `issuer_before` / `issuer_after`, whether the fresh sign-in carried an `auth_time`), written in the same transaction as the two `server_config` upserts. If the audit row cannot be written, switching ON and setting or changing an issuer is refused and nothing is saved; switching OFF with the issuer unchanged (or cleared) is applied anyway (the kill switch is never blocked by an unwritable audit table) and the page says that the audit entry is missing. The Admin UI path needs a fresh IdP sign-in: when the IdP is down use the SQL rollback.
- **Effect.** The saving node answers at once; every other node within `NEBU_OAUTH_CONFIG_CACHE_MS` (default 2 s, at most 5 s). A read that started just before the commit can refill the node cache with the old value for at most one TTL.
- **Status list.** The section lists what the server can see itself, each item prefixed with `OK`, `Attention` or `Note`: the stored switch and issuer; whether THIS node answers `auth_metadata` with 200 right now (and the propagation note when it differs from the stored setting); `NEBU_TRUSTED_PROXY_CIDRS` is empty (every per-IP limit and per-source cap is global behind a proxy, G3-2; right only when clients connect directly); the issuer host differs from `NEBU_SERVER_NAME` (right only with `.well-known` delegation); `matrix_oidc_refresh_mode` is online while `oauth_idp_revalidation` is `per_refresh` (OAuth logins would be refused: the IdP issues no refresh token); an insecure admin session; the re-authentication opt-out. **None of this blocks saving and none of it says that OAuth is ready.** The server cannot see the load balancer, whether the client addresses it forwards are the real ones (the positive client-IP test of G3-2), what the IdP puts into `auth_time` or how the clients behave: those and the manual verification groups A-F stay the operator's job.
- **Local stack.** `dev/tls/oauth.sh` (`make dev-tls-oauth-on` / `-off`) stays; it writes the same two keys with SQL.

### Admin configuration forms and their protection (story admin-config-privileged-forms-sweep)

Every form under `/admin/config*` is behind the admin role, the Phoenix CSRF token and strict fetch metadata (Chrome / Firefox the four `Sec-Fetch-*` headers, Safari the click proof `_click_proof`, a notice page instead of a 403); the pages of the forms below are not framable and `no-store`. The forms that grant authority or widen trust additionally need a **fresh sign-in** (5 minutes, bound to the page, single use, consumed by a successful save), listed in the table below.

**How the sign-in is asked for (story admin-reauth-button-flow).** The page itself shows whether you must sign in again, so you sign in BEFORE you enter the change. Without a valid marker for the page the primary button of such a form is a link styled as a button, "Sign in again to save" ("... to approve" / "... to revoke" on the OAuth client confirm pages): it leads through the IdP and back to the same page, and the form's hint says to sign in first (anything typed before the round trip is lost; nothing is replayed or pre-filled, the storage access key and secret key are never filled in). With a valid marker the normal submit button ("Save", "Save SSO schemes", "Approve client", ...) is shown and its hint says how many whole minutes the sign-in was still valid when the page was opened (no countdown: a page left open does not update) and that it covers one save on this page. After a successful save the marker is consumed and the link is back. The server still decides: a POST without a valid marker (for example when the 5 minutes ran out while the page was open) is refused and redirected to the sign-in exactly as before, nothing is saved, and no secret or trust-list value appears in the redirect URL or in a log line, also at the `debug` level: the Phoenix logger masks (`config :phoenix, filter_parameters`, a deny-list in `config/config.exs`) the storage `access_key` and `secret_key`, every field whose name contains `endpoint` (the plain storage endpoint and `iam_endpoint` / `sts_endpoint`: a value pasted with user info such as `user:password@host` is logged by the framework before the validation refuses it), `webhook_url`, the SSO scheme and origin lists, the issuer URL and the claim and role values, and the request logger (`Nebu.Web.Plugs.RequestLogger`) does not capture request bodies of `/admin/*` at all (its key list does not know these field names; a new admin form is covered without a list; the decision is made on the percent-DECODED first path segment, so `/%61dmin/...` is covered too). The other fields of these forms (bucket, region, key prefix template, `use_ssl`, the numeric media limits, checkboxes) are not secrets and do appear in the Phoenix logger's parameter line. **The IAM / STS endpoint URLs refuse user info** (any `@`, so also `https://user:pass/word@host`, in the form check and again in `Nebu.Media.StorageConfig.upsert/1`, before the SSRF check): the page says "The URL must not contain a user name or password", neither the message, the log nor the re-rendered form contains any part of the URL (a rejected plain endpoint with an `@` is not echoed either); a URL rejected for another reason is logged by its host only. NEW secret-carrying fields of a form must be added to `filter_parameters`. A marker is bound to one page path: a sign-in made for `/admin/config/claim-mapping` does not unlock `/admin/config` (the OIDC scopes and refresh mode forms and the storage "Test Connection" need no sign-in and stay plain buttons in every state). **Enter key in the "Sign in again" state (accepted trade-off).** A form with exactly one text field still submits on Enter although its submit button is a link: the SSO schemes form, the SSO origins form, the OAuth switch (the issuer field) and the role mapping (`admin_group_claim`). That POST is refused and redirected to the sign-in as above (nothing is saved, nothing is replayed). On the storage target form the first submit button is "Test Connection", so Enter there runs a test connection (a `:click` gate form that persists nothing) and not a save. After the sign-in the notice says "Signed in again. Nothing is changed yet: enter your change and press Save." (it is the same after a link sign-in and after a refused POST; it names no minutes, because a flash can be read long after the sign-in: the validity line of the form carries them). On the role mapping a refusal that a new sign-in can change (the value is not in the token that was recorded) shows a fresh "Save" button and, next to the error, an explanation and the link "Sign in again, then enter the value once more".

The forms, their protection and the reason:

| Form | Page | Protection | Why |
|---|---|---|---|
| SSO redirect origins, SSO redirect schemes | `/admin/config` | strict + fresh sign-in; audit rows `sso_redirect_origins_changed` / `sso_redirect_schemes_changed` | redirect sinks for a `loginToken` |
| OAuth 2.0 authorization server | `/admin/config` | strict + fresh sign-in + acknowledgement; audit row `oauth_switch_changed` | see "The Admin UI switch" |
| Role mapping (`admin_group_claim`) | `/admin/config/role-mapping` | strict + fresh sign-in; audit row `admin_group_claim_changed` | decides who is an administrator |
| Claim mapping (`oidc_user_id_claim`, `oidc_displayname_claim`, `oidc_email_claim`) | `/admin/config/claim-mapping` | strict + fresh sign-in; audit row `oidc_claim_mapping_changed` (claim names) | decides which IdP claim identifies a user |
| OIDC scopes, OIDC refresh mode | `/admin/config` | strict fetch metadata only, NO fresh sign-in; audit rows `oidc_scopes_changed` / `oidc_refresh_mode_changed` | they grant no authority by themselves (except on an instance WITHOUT a configured admin claim path, where the admin check scans every claim and an extra scope can feed it, the already accepted scanner risk) but change the claim set the IdP issues and the token lifetime; the fresh sign-in would use the very scopes / refresh mode the form changes, a wrong value would lock you out of the sign-in needed to correct it |
| Media policy (`/admin/media/settings`) | `/admin/media/settings` | strict + fresh sign-in (one marker for this page, shared with the storage target); audit rows `media_config_updated`: for `released_delete_after_days`, `deleted_days` and `infected_days` written in one transaction with the value (story media-retention-audit-atomic; when the row cannot be written a **shortening** is refused with "Failed to save media settings" and nothing changes, a **lengthening** or disabling is saved without the row), for the other keys best-effort after the value | irreversible deletion settings (`released_delete_after_days`, `deleted_days`, `infected_days` of 0 destroy released attachments and infected evidence) and the alert webhook. **Break-glass while the IdP is down (for example to extend `deleted_days` and keep evidence):** `UPDATE media_config SET value = '90', set_at = (extract(epoch from now()) * 1000)::bigint WHERE key = 'deleted_days';` (one row per key; the row wins over the default; the nodes re-read within 60 seconds). **The value must be plain digits** (`90`, not `90d`, `' 90'` or `1e3`; `deleted_days` / `infected_days` at most 3650): a wrong value shows a warning on `/admin/media/settings` naming the key and keeps that key at its default (the other keys keep their values); for `deleted_days` / `infected_days` the automatic cleanup is paused (nothing deleted) until the row is fixed, by SQL or by saving the form (story media-config-tolerant-loader). **Saving the form writes the value shown in the field and resumes the cleanup with it**, so set the intended window first. A damaged key the form does not carry (the alert thresholds `clamav_down_alert_minutes`, `signature_stale_alert_hours`, `backlog_depth_alert_threshold`, `scan_failed_rate_alert_pct`; `scan_kill_switch`; `mime_denylist`) is listed on the page as not editable there and is repaired the same way: `UPDATE media_config SET value = '5', set_at = (extract(epoch from now()) * 1000)::bigint WHERE key = 'clamav_down_alert_minutes';` (plain digits), or `DELETE FROM media_config WHERE key = 'clamav_down_alert_minutes';` to fall back to the default |
| Media storage target | `/admin/media/settings` | strict + fresh sign-in (same marker); audit row `media_storage_config_updated` | every future upload goes to the configured store: a changed endpoint sends the files to another host. **Break-glass while the IdP is down:** SQL on `media_storage_config` (the database row wins over the environment variables, a changed environment cannot fix it): `UPDATE media_storage_config SET endpoint = NULL, bucket = NULL, region = NULL, use_ssl = NULL, access_key_encrypted = NULL, secret_key_encrypted = NULL, set_at = (extract(epoch from now()) * 1000)::bigint WHERE id = 1;` clears the stored target so that the environment variables apply again (the credential columns hold `SecretBox` ciphertext and cannot be set in plain text by SQL); every node re-reads the table within 60 seconds (TTL), no restart |
| Test connection (storage form) | `/admin/media/settings` | strict only, no sign-in, never touches the marker | persists nothing. The stored access / secret key are used only for the STORED endpoint and scheme: for any other endpoint the form must contain the access key and the secret key ("Enter the access key and secret key to test a different endpoint"). The request is **pinned** to the address the SSRF check resolved (no second DNS resolution, so no DNS rebinding between the check and the request; story storage-test-pinned-target, see "The storage test connection is pinned" below) |
| Log retention | `/admin/logs/config` | strict only; audit row `log_settings_changed` in the same transaction (refused when the row cannot be written, except a pure "collection off" change) | shorter retention deletes INFO / DEBUG rows, DEBUG collects more personal data; no sign-in so that an operator can raise levels while the IdP is broken |
| Delete device, force-leave, force-join, rooms / spaces (create, visibility, archive, auto-join, children), device rename | `/admin/users/...`, `/admin/rooms/...`, `/admin/spaces/...` | strict only | one rule for every admin form post: a real click of the administrator (Safari: the click proof); no sign-in so that the incident-response actions work while the IdP is down. The room auto-join toggle writes its audit row `room_auto_join_changed` (best effort, after the write, like the space toggle: follow-up `dn`). The space edits (name, topic, add / remove child) write `space_name_changed` / `space_topic_changed` / `space_child_added` / `space_child_removed` (best effort, after the event; see "Space edits and the audit log" below) |

**Space edits and the audit log (story space-edit-audit, follow-up `dj`).** `POST /admin/spaces/:id` (name and topic), `POST /admin/spaces/:id/children` and `DELETE /admin/spaces/:id/children/:child_id` write one `audit_log` row per edit through `Nebu.Matrix.set_space_state/5`: `space_name_changed` (metadata `name`), `space_topic_changed` (metadata `topic`), `space_child_added` and `space_child_removed` (metadata `child_room_id`, the unlink is the `m.space.child` event with empty content). Actor = the Matrix id of the acting administrator, target = the space room id (`target_type` `room`), outcome `success`, and the metadata carries the `event_id` of the state event so the row links to the `events` record. Name and topic are cut to 256 characters in the row (the event keeps the full value); no user data, no message content. A refused or failed edit (not a member, no power level, unknown room) writes no row. **The row is not atomic with the event:** the event is emitted through the Room process (own process, signed, fanned out; `rooms.name` is a separate update), one database transaction cannot span it; the same reason as for the audits of the room auto-join toggle, the visibility change and the member add. **Policy when the audit row cannot be written:** a failed audit write is logged (one ERROR with the action, the room id and the error kind, never the name or topic; an exception or an exit of the writer such as a pool timeout is caught the same way), the edit is kept (the audit failure does not undo the edit and does not fail the request: the page still answers "Space saved"), because these edits are non-destructive and reversible and independent of confidentiality, unlike the privileged config saves above, which widen access and are therefore saved together with their row. The `events` row (sender = the administrator, type, content, append-only) stays the primary record of a space edit; the audit row makes it visible in the audit log view and export without knowledge of the Matrix event model. A Matrix client that edits a space with `PUT /_matrix/client/v3/rooms/{roomId}/state/...` is not an admin action and writes no space audit row (the audit is written at the admin entry point, not in the generic `set_room_state` path). `create_space` is not part of this audit. Decided without audit (owner decision 2026-10-15, follow-ups `dk`, `dl`, `dm`): `configure_logging` of the Trace Map, War Room start / stop and the media diagnosis, bootstrap completion and admin login / logout.

**The storage test connection is pinned (story storage-test-pinned-target, follow-up `do` part a).** The test connection resolves the candidate endpoint host ONCE in the SSRF check (`Nebu.Media.SSRF.checked_target/2`, every answer is checked) and sends its `ExAws` request to exactly that **checked address**: the connect address is the pinned IP, the host name is never resolved a second time, so a DNS server cannot answer a public address to the check and a private one to the request (DNS rebinding, time-of-check / time-of-use). The original host name stays in the request: the `Host` header (the SigV4 signature is computed over it, a MinIO or S3 server accepts it as before), for https the TLS SNI and the certificate hostname verification (a certificate valid only for the IP is refused, the request is not sent), and a default port (443 / 80) stays out of the signed host. A redirect answer is not followed (it would leave the pinned address), there is no connection pooling and a request without a pinned target fails closed. A literal IP endpoint, `use_ssl: false` and the `NEBU_STORAGE_ALLOW_PRIVATE_ENDPOINTS` opt-in behave as before; a blocked or unresolvable endpoint still fails before any request with the same message. The save (`upsert/1`) makes no request, it only validates, so there is nothing to pin there. **Residual (operational calls):** the operational S3 calls of `Nebu.Media.Storage` (upload, download, delete, the sweeps) use the STORED endpoint and resolve its host name per request: a rebinding AFTER a successful save / test is a residual of the admin-trusted endpoint (admin only, fresh sign-in, strict gate), recorded as a follow-up, not fixed by this story. **Proxy and addresses:** the test connection speaks HTTP/1.1 only and pins the FIRST resolved address (a multi-record host whose first node is dead fails the test deterministically); if the server runs behind a proxy configured by environment variables (`HTTP_PROXY` / `HTTPS_PROXY`), the proxy sees the IP (for https a `CONNECT ip:port` with the SNI of the name, the certificate is still verified against the name), and `NO_PROXY` is matched against the IP instead of the host name, so host-name entries no longer apply to the test connection (the operational calls keep going by host name). An endpoint with user info (`user@host`) is refused. **Defect found and fixed with it:** the production test connection raised a `CaseClauseError` against ANY server (hackney 4.x answers a `HEAD` with a 3-tuple that `ExAws.Request.Hackney` does not match, so the form showed a failure even for a healthy store); the pin client maps that answer and a 403 / 404 / 5xx now arrives as an HTTP error status.

The bootstrap wizard (`/admin/bootstrap*`) is not gated: no admin and no IdP sign-in exist before it completes. Other admin forms (logs retention, media settings and storage target, users, rooms, spaces) are not part of this table (follow-up `de`).

The bootstrap wizard, `GET /admin/logout` and the LiveView events (media block / unblock / delete / rescan / override, War Room, Trace Map capture) are not gated by fetch metadata (the websocket carries none): a script on the shared origin (SO7) can use them; see ADR-033 SO11. **The audit row is saved with the change (story admin-config-audit-atomic).** Every form of the table above writes its audit row in the same database transaction as the setting. If the audit row cannot be written, the role mapping, the claim mapping, a **widening** of the SSO origin or scheme list and a widening of the OIDC scopes are NOT saved ("<form> not saved: the audit entry could not be written, so nothing was changed"; try again, ask the operator to check the database and the server log). The ways back are applied anyway and the page says "... saved, but the audit entry could not be written": a list or scopes value that is a **subset** of the stored one (narrowing or clearing) and an OIDC refresh mode change to `online` (a change to `offline` is refused: it adds `offline_access`); one value-free ERROR is logged. A broken audit table therefore never blocks a roll-back; the operator's functions in the running node (`bin/nebu rpc`, below) write the value first and the audit row second. **SIEM:** a filter on `sso_redirect_origins_changed` must also watch `oauth_switch_changed`: the issuer origin of the OAuth switch is a trust source of the legacy SSO login too. **A role mapping that is too BROAD is as dangerous as one that is wrong:** a value that occurs in every token (the issuer URL, the client id, `offline_access`, `default-roles-<realm>`) makes every user an instance administrator, above all on an instance whose bootstrap stored no `admin_group_claim_path` (the admin check then scans ALL claims). The page refuses the known universal values; use a group that only administrators have. **The role mapping refuses a value you would not satisfy yourself (story role-mapping-self-lockout-guard).** The page compares the new value with the values of the fresh sign-in the save needs (the string values at the stored claim path, or anywhere in the token when the bootstrap stored no path; exact, case sensitive) and answers "This value is not in your own sign-in token" without saving: join that group at the identity provider, sign in again and save. Be aware that other administrators lose access when their token lacks the value; that is the purpose of the change. There is no override: to hand the role over to other people let them save it, or use the operator's rpc below (not guarded). If the sign-in of your session was made before this check existed (rolling deploy) the page says "did not record which values your token holds": sign in again. **Refresh token size:** the admin session is a signed 4 KB cookie that holds the encrypted refresh token; the re-authentication for THIS page adds about 260 bytes (the fingerprint), so an IdP whose refresh tokens are larger than about 1 KB (some opaque Entra ID tokens) makes the re-authentication of the role mapping page fail with a server error (fail closed, nothing is saved; use `bin/nebu rpc 'IO.inspect(Nebu.Release.reset_admin_group_claim("<value>"))'` instead). If your token has more than 32 distinct values under the claim and the value is not among the first 32 recorded (in sorted order), the page says it cannot be checked and gives the rpc command. On an instance whose bootstrap stored no claim path the check ignores protocol and identity claims (`sub`, `email`, `name`, `typ`, `acr`, ...): a value that is only there is refused. The page shows the claim path it looks in; "Sign in again" next to the refusal starts a new fresh sign-in (the kept sign-in is valid for 5 minutes). **Lock-out recovery.** A wrong **role mapping** locks ALL administrators out at their next sign-in or session refresh (the admin check is evaluated again, so an open session cannot undo it: the fresh sign-in the correction needs fails as well) and can only be corrected with SQL. A wrong **claim mapping** maps sign-ins onto the wrong Matrix accounts; administrators stay administrators (the admin check does not use that claim), so the correction can be made on the claim mapping page again with a fresh sign-in. SQL for the role mapping as a role that may write `server_config` (the runtime role `nebu_app`: the key is in its update allowlist since migration 000049; any role with `BYPASSRLS` or a superuser works too; `FORCE ROW LEVEL SECURITY` binds the table owner as well; `set_at` is milliseconds): `UPDATE server_config SET value = 'instance_admin', set_at = (extract(epoch from now()) * 1000)::bigint WHERE key = 'admin_group_claim';` (`admin_group_claim` is the group VALUE the admin check looks for under the claim PATH `admin_group_claim_path`, which the Role mapping page does not change: a new value must occur in that claim of the administrators' tokens; the default is `instance_admin`; the check reads the value on every request, no restart is needed). **`oidc_user_id_claim` is cached per node (`persistent_term`) and only the Admin UI save invalidates that cache cluster-wide: if you correct it with SQL, either restart the server nodes (rolling) or, better, save the corrected value once on the claim mapping page afterwards.** **Migration 000049** (`config_admin_group_claim_mutable`) adds `admin_group_claim` to the update allowlist of `server_config`: before it every save of the Role mapping page raised an RLS error on a bootstrapped instance (a pre-existing gap of the same class as 000048); run the migrations before using the page. **Without database access** (UpCloud / Stackit VM without a console) use the release functions in the running node, they need no sign-in and write an audit row (actor `operator:rpc`): `bin/nebu rpc 'IO.inspect(Nebu.Release.reset_admin_group_claim())'` (default value `instance_admin`, or pass your admin group), `bin/nebu rpc 'IO.inspect(Nebu.Release.reset_oidc_scopes())'` (empty extra scopes: only `openid`) and `bin/nebu rpc 'IO.inspect(Nebu.Release.disable_oauth())'` (the kill switch, also when the IdP is down so that no fresh sign-in is possible). **Before you switch OAuth on from the Admin UI, prove that one of these emergency paths (rpc or psql) works on THIS instance.**

**Atomic audit of the media retention values (story media-retention-audit-atomic, follow-up `dn`; owner decision 2026-10-15: only these three values).** `released_delete_after_days`, `deleted_days` and `infected_days` decide when stored media is deleted (all three take effect: the daily `MediaCleanupWorker` reads `deleted_days` / `infected_days` from this table at every run, story `media-cleanup-reads-media-config`, follow-up `du`, see "Media retention windows" below; `released_delete_after_days` is read by its own worker). `Nebu.Media.Config.upsert/3` writes such a value and its `media_config_updated` row in ONE database transaction (the old value is read under a per-key lock inside the transaction, so two concurrent saves cannot turn a checked lengthening into a shortening). **Policy when the audit row cannot be written, per direction:** a **shortening** (`deleted_days` / `infected_days`: a smaller number; `released_delete_after_days`: "off" to a number, or a number to a smaller one; for this key unset and 0 both mean "off", because the worker treats 0 like unset) is refused, nothing is saved, the page shows the generic "Failed to save media settings" and the server log holds one ERROR (`shortening refused`, the key only, no values); a **lengthening**, disabling (`released_delete_after_days` to unset) or an unchanged value is saved without the row after one value-free ERROR (`applied without audit`), so the way to more retention stays open when the audit table is broken. **Known per-key limitation (unchanged):** the media policy form calls `upsert/3` once per changed key, in sorted key order, without a transaction across the keys: when a later key is refused, the earlier keys of the same save stay committed (the page shows the failure; open it again to see what is stored). **The remaining audits stay best-effort** (written after the change, a failure is only logged; not implemented, owner: only the three retention values): the other media policy keys (`max_upload_size_bytes`, `webhook_url`, `mime_denylist`, the limits and alert thresholds), the storage target (`media_storage_config_updated`) and the room / space auto-join toggle (`room_auto_join_changed`; `Nebu.Matrix.set_room_auto_join/3` ignores the writer's result).

**Media retention windows (story media-cleanup-reads-media-config, follow-up `du`).** The daily `MediaCleanupWorker` hard-deletes `:deleted` rows older than `deleted_days` and `:infected` rows older than `infected_days`. It reads both from `media_config` (the Admin media settings) at EVERY run (no restart, no cache). Without a stored value the effective retention is **30 days (deleted) and 7 days (infected)**, exactly what the worker used before (the former `config :nebu, :media_cleanup` block is gone; the catalogue default of `infected_days`, which the form displays, was 90 and is now 7 so that the form states the truth; **owner decision pending**: whether infected evidence should be kept longer than 7 days by default, as story 9a's rationale suggests, which is one default and this paragraph). **Fail-safe:** when the table cannot be read or a stored value is not an integer from 0 to 3650, the run deletes nothing from `:deleted` / `:infected`, logs one ERROR (`retention config unavailable, nothing deleted`, no value) and tries again at the next run; the completion sweep of rows that are already hard-deleted still runs. `0` days is the shortest retention (delete at the next run). Every run logs the windows it used at INFO. **Behaviour change on upgrade:** a value an admin saved earlier (it had no effect so far) becomes effective at the next run; run this BEFORE deploying the release: `SELECT key, value FROM media_config WHERE key IN ('deleted_days', 'infected_days');` (no rows = the defaults above; a value shorter than 30 / 7, for example a `0` saved while it had no effect, deletes the matching media at the first run, irreversibly). `0` for either value means "delete at the next run", unlike `released_delete_after_days` where `0` means off; `deleted_days` also bounds the grace period of the rows `MediaReleasedAutoDeleteWorker` marks `:deleted`. A stored value that is not an integer from 0 to 3650 stops the cleanup (see above); only that key then uses its default in the Admin form, which shows a warning naming it (the other settings keep their stored values; story media-config-tolerant-loader, follow-up `ej`): fix such a row by SQL or by saving the form (the form writes the value shown in the field and so resumes the cleanup with it). The strict read accepts plain digit strings of 1 to 18 digits, leading zeros included (`0003650` = 3650, `0000000` = 0 = delete at the next run; accepted: the form never writes leading zeros, so this only matters for a hand-written row). The Admin form shows a hint next to both fields.

**createRoom `initial_state` (story create-room-initial-state-conformance, follow-up `dx`).** `POST /_matrix/client/v3/createRoom` has applied `initial_state` since the Go -> Elixir migration; it now validates the structure before the room exists (`400 M_BAD_JSON` / `M_NOT_JSON` / `M_INVALID_PARAM`, a NUL character is refused) and a persistence failure of one entry fails the creation (`500`, the half-created room is deleted) instead of a `200` with a half-configured room. Element's normal requests are not affected. Contract and the createRoom keys that are not read yet: `docs/matrix-api-scope.md`.

**createRoom / state input validation (story create-room-input-validation, follow-ups `ed`, `ee`, `eg`, `ei`).** Behaviour changes clients can see: (1) `POST /createRoom` now honours `room_version` and `room_alias_name`. Nebu supports exactly room version `10`: any other `room_version` answers `400 M_UNSUPPORTED_ROOM_VERSION` (a non-string `400 M_BAD_JSON`), and `GET /capabilities` lists only `{"default": "10", "available": {"10": "stable"}}` (it used to advertise versions 1-11 although every room was created as 10); `POST /rooms/{id}/upgrade` requires `new_version` (`400 M_MISSING_PARAM` / `M_BAD_JSON` / `M_UNSUPPORTED_ROOM_VERSION`, a missing value no longer falls back to 10). An explicit `room_alias_name` registers exactly `#<localpart>:<server_name>` (`400 M_ROOM_IN_USE` when it is taken, `400 M_INVALID_PARAM` for an invalid localpart) and wins over the alias that Nebu derives from the room name (the derived alias is only registered when no `room_alias_name` is sent, as before). (2) The aliases in an `m.room.canonical_alias` event (`PUT .../state` and `initial_state`) must be valid and point to the room (`400 M_INVALID_PARAM` / `M_BAD_ALIAS`; aliases that are already in the current state or removed are not checked). (3) A room name is capped at 255 characters (`400 M_INVALID_PARAM`; a non-string or NUL-containing name `400 M_BAD_JSON`), state content nests at most 32 levels and a NUL in a state body is a `400` instead of a `500`. (4) Failure logs of room creation and state writes name only the room id, the event type and the error class, never a name, alias or content. Existing rooms are not changed. Contract: `docs/matrix-api-scope.md`. A `creation_content` that nests deeper than 32 levels or contains a NUL is `400 M_BAD_JSON` (no room), a `room_alias_name` may not contain Unicode control or format characters (zero-width, bidi override, BOM, C1 controls), and an `m.room.canonical_alias` event names at most 64 distinct aliases (Nebu policy).

*Operator check after the upgrade (canonical aliases that were accepted before they were validated).* Until this story `PUT .../state/m.room.canonical_alias` and `initial_state` stored any alias content. This read-only query lists every room whose CURRENT `m.room.canonical_alias` event (per `state_key`) names an alias that has no `room_aliases` row for the SAME room (a claim that does not point to the room; rooms created by an upgrade also show up, because the copied alias still maps to the old room, which is expected). Run it with a read-only role; Nebu does not repair these rows (an unchanged alias can still be re-saved, a changed one is validated), a room owner removes the claim with a new `m.room.canonical_alias` event (`{}`).

```sql
WITH cur AS (
  SELECT DISTINCT ON (room_id, state_key)
         room_id, state_key,
         CASE WHEN jsonb_typeof(content) = 'object' THEN content ELSE (content #>> '{}')::jsonb END AS c
  FROM events
  WHERE event_type = 'm.room.canonical_alias' AND state_key IS NOT NULL
  ORDER BY room_id, state_key, origin_server_ts DESC
), claims AS (
  SELECT room_id, state_key, c ->> 'alias' AS alias
  FROM cur
  WHERE jsonb_typeof(c) = 'object' AND coalesce(c ->> 'alias', '') <> ''
  UNION
  SELECT cur.room_id, cur.state_key, a.alias
  FROM cur, jsonb_array_elements_text(
         CASE WHEN jsonb_typeof(cur.c -> 'alt_aliases') = 'array' THEN cur.c -> 'alt_aliases' ELSE '[]'::jsonb END
       ) AS a(alias)
  WHERE jsonb_typeof(cur.c) = 'object'
)
SELECT cl.room_id, cl.state_key, cl.alias
FROM claims cl
LEFT JOIN room_aliases ra ON ra.alias = cl.alias AND ra.room_id = cl.room_id
WHERE ra.alias IS NULL
ORDER BY cl.room_id, cl.alias;
```

**Join rule enforcement, createRoom presets, topic and power level override (story create-room-presets-power-levels-topic, follow-ups `ec`, `ef`, `ea`). SECURITY FIX with a behaviour change on upgrade.**

**RELEASE GATE LIFTED: this branch may be released to Element-based deployments** (story rate-limits-join-invite-create-room, 2026-10-19). Follow-ups `ev` and `ez` are CLOSED by story sync-membership-partition (2026-10-17): `/sync` is partitioned by membership, invitees see invitations and DMs in Element (`rooms.invite` with a stripped invite state that includes the invitee's own invite event with `is_direct`) and can accept or decline them, and a user who left, was kicked, banned, removed by an Admin or declined an invitation stops receiving the room's events at the leave (`rooms.leave` once, bounded at the leave event or at the end of the membership row; residuals: `fc` late commits, `ex` was the half-state ban, now closed; `fd` closed by story sync-token-per-device: the since token is stored per device, device-less clients keep the per-user token, `cj`). Follow-up `ey` is CLOSED by story rate-limits-join-invite-create-room: per-user rate limits for `createRoom` (charged per invitee), `POST /rooms/{id}/invite` and `POST /join`, and caps of pending invitations (per-inviter cap 500, per invitee 100, per inviter-invitee pair 10) bound the invite-spam vector in COUNT (the byte size of one invitation in `/sync` is bounded by a response budget, not by a limit at write time: follow-up `ep` stays open as the next story; the other residuals `fi` (a)-(e) do not gate: per-node tiers, uncapped writers `upgrade_room` and Admin force-add, an attacker with several accounts can still occupy a victim's 100 invitation slots until the victim ignores the inviters or they are deactivated, a deactivated user is still visible in the profile oracle, env-only values): invitations are now VISIBLE in Element (a `createRoom` can invite 50 users with an attacker-chosen name and topic; the sync side of the ignore list `m.ignored_user_list` exists). Invite blocking (`M_INVITE_BLOCKED`, `m.invite_permission_config`) is split to follow-up `fh` (not a MUST for a server that advertises at most v1.15). The batch is no longer gated by `ey`. `ex` is CLOSED by story moderation-routes-atomic-ban: the ban route exists and a ban is ONE atomic call in the room process (see "Room moderation" below). Release notes to acknowledge for any deployment that takes the change: (1) it is a security fix: private rooms are no longer open to anyone who knows the room id, and bans that already exist as `ban` events are enforced on join (a leave no longer lifts one; the check is atomic inside the room process); a ban can be issued now (`POST /rooms/{roomId}/ban`, with `/kick` and `/unban`, see "Room moderation" below), and the member set AND event order are protected: a ban is one atomic call in the room process, so a join, invite or decline racing it cannot hide it (follow-up `ex`, CLOSED); (2) rooms without a join rule are invite-only now: run Q1 below and restore `public` where it was intended; (3) invitations are shown in Element now (`rooms.invite`, DMs included: the partner sees the invitation and accepts or declines it; `/join <room id>` is no longer needed); invitations that exist before the update are not pushed to a client that already has a sync position: they appear with the client's next initial sync (Element: Clear cache and reload, or a new login); an invitation or leave older than a client's token is not re-delivered incrementally; (3a) a user who left, was kicked, banned, removed by an Admin or declined an invitation stops receiving the room's events at once (a SECURITY fix, `ez`: until now every new event of such a room, message content included, was delivered in `rooms.join` until the user forgot the room); the room is delivered once in `rooms.leave`; since story sync-token-per-device (follow-up `fd`, closed) the since token is stored per device, so a leave also reaches the user's other clients; after the update each client does one full initial sync once (a token issued before the update is not migrated: Element shows nothing special, the answer is just larger), then syncs incrementally from its own device row; a client authenticated with a raw IdP JWT that has no device binding keeps the per-user token (`cj`); the global account data (Element's secret storage) and the own cross-signing change now reach every device, and a global account data write ends a waiting `/sync` at once (migration 000052 adds the sequence `sync_global_pos_seq` and four position columns; the SQL has no data statement, but see the table rewrite below). *Migration 000052, locks and duration:* the column `account_data.stream_pos` has a VOLATILE default (`nextval`), so PostgreSQL REWRITES the whole `account_data` table (every row, its content of up to 1 MB per row and the TOAST data included) under an ACCESS EXCLUSIVE lock, and the index `account_data_user_pos_idx` is built in the same transaction (not concurrently, like 000051: every migration runs in one transaction); every global account data read and write (each `/sync`, each account data PUT) waits until the commit, the duration grows with the table size and there is no lock timeout: run it in a maintenance window. The other three columns have a constant default (catalog-only). *No mixed-version window:* an old node does not fail on the new columns, but its overwrite of a global account data entry keeps the old position and its cross-signing upload stamps none, so such a write reaches device-bound clients only with the type's next change or their next initial sync: deploy all nodes at once (stop the old nodes before the new ones serve), or accept that; (4) the Admin "Visibility: Public" toggle is a label only (follow-up `et`), an Admin force-add of a banned user fails and the Admin UI has no unban (unban a user through the member's profile in Element, `/unban <user id>` in the composer or the API); (5) the new `createRoom` 400s below; (6) run Q2 for the incident review.

*Limits of the room membership writes (story rate-limits-join-invite-create-room, follow-up `ey`; release note 7).* Three per-user token buckets (per node, in memory, keyed by the authenticated user, never by IP) and three caps of pending invitations (in PostgreSQL, cluster-wide). Tiers: `create_room` 10 per minute, burst 20 (`POST /createRoom`); `invite` 20 per minute, burst 50 (`POST /rooms/{id}/invite`, and one unit per distinct invitee of a `createRoom`); `join` 12 per minute, burst 30 (`POST /join`, an idempotent re-join included). A refused request is `429 M_LIMIT_EXCEEDED` with `Retry-After` and `retry_after_ms`. Caps: 500 pending invitations per inviter, 100 per invitee, 10 per inviter-invitee pair; a refused invitation is `403 M_FORBIDDEN` ("You have too many pending invitations: wait until some of them are accepted or declined", "... to this user", "The invited user has too many pending invitations"). Tuning: `NEBU_RATE_LIMIT_CREATE_ROOM_PER_MIN`, `NEBU_RATE_LIMIT_CREATE_ROOM_BURST`, `NEBU_RATE_LIMIT_INVITE_PER_MIN`, `NEBU_RATE_LIMIT_INVITE_BURST`, `NEBU_RATE_LIMIT_JOIN_PER_MIN`, `NEBU_RATE_LIMIT_JOIN_BURST` and `NEBU_INVITE_MAX_PENDING_PER_INVITER`, `NEBU_INVITE_MAX_PENDING_PER_INVITEE`, `NEBU_INVITE_MAX_PENDING_PER_PAIR` (strictly positive integers; anything else keeps the default). Two rules keep the limiter sound: burst / rate_per_min must be at most 60 (idle buckets are evicted after an hour) and the invite burst must be at least 50 (a valid `createRoom` with 50 invitees must be satisfiable); a pair that breaks a rule falls back to the default pair of its tier and the server logs one warning per rejected setting at boot (variable name only, never the value). `NEBU_RATE_LIMIT_DISABLED=true` disables the three tiers but does not disable the pending caps. What users see in Element: a refused `createRoom` is the dialog "Failure to create room"; a refused join is the dialog "Failed to join"; a refused invite is retried silently every 5 seconds until it passes; a cap is "You do not have permission to invite people to this room" and stops the batch. Per node: with N nodes behind a load balancer that does not pin a user to a node a user can spend up to N x the budget. The caps are a cluster-wide count bound: they are counted and written under PostgreSQL advisory locks (inviter and invitee), so concurrent client invitations cannot exceed them on any node; rows written by `upgrade_room` and the Admin force-add are counted but never refused, so a large upgrade can fill the upgrader's own cap, and invitations that exist from before this release count too. The invitee total does not count rows of a deactivated inviter or of an inviter on the invitee's `m.ignored_user_list` (Element: Decline, then ignore the user), so a victim can free the slots an attacker took; the pair cap (10) bounds what ONE account can place. A victim whose 100 slots are occupied by colluding accounts refuses legitimate inviters with the invitee 403 until those rows are accepted, declined, ignored or deactivated (there is no withdraw route: `fb`). `POST /rooms/{id}/upgrade` spends one `create_room` unit (it creates a room). The `rooms.invite` section of one `/sync` response is bounded in BYTES by a budget: an optional stripped event (topic, avatar, canonical alias, encryption, join rules, name) of more than 64 KiB, and then the largest optional events while the response total exceeds 8 MiB, are left out of `invite_state`; an invitation and its member events are never dropped, and an `m.room.create` above 64 KiB is reduced to its spec keys (`creator`, `room_version`, `type`, `predecessor`). The optional stripped state is bounded; create and member content stays unbounded until `ep` (the 65536-byte event limit at write time is follow-up `ep`, the next story, not part of this change), so one response can still carry the member and create content of up to 100 invitations. The count reads the invitee's `m.ignored_user_list` (up to 1 MB of account data) once per invitee, never per row, and needs PostgreSQL 16+ (`pg_input_is_valid`; on an older server every invitation with invitees fails closed with a 500). When another invitation of the same inviter or to the same invitee holds the advisory locks for more than 2 seconds (`lock_timeout`), the request is answered `503 M_LIMIT_EXCEEDED` (fixed text, nothing written; Element retries it). Migration 000050 adds a partial index on `room_invitations (inviter_id, invitee_id)` for the counts; the plain `CREATE INDEX` takes a SHARE lock on `room_invitations` while it builds (writes wait for that moment, the table is small).

*What the server did before (the old implicit behaviour).* Until this story `POST /_matrix/client/v3/join/{roomId}` checked only the `restricted` join rule. Every other room was an open-join room: any authenticated local user who knew a room id could join it and read its history, whatever the room was meant to be: private rooms, DMs, private Spaces, Admin-created rooms, personal rooms and rooms with an explicit `invite` join rule (the rule was ignored). Room ids are random, but they are not secrets (matrix.to links, `m.space.child` / `m.space.parent` state, invitations, upgrade tombstones, and every former member knows them). Bans and kicks were not enforced on join either: a banned user could join again immediately. `createRoom` wrote no preset events (`preset` and `visibility` were not read, there were no `m.room.join_rules`, `m.room.history_visibility` or `m.room.guest_access` events unless the client put them into `initial_state`), so an Element public room had no join rule and was displayed as `invite` by the room summary and the Space hierarchy, `power_level_content_override` and `topic` were ignored.

*The new rules* (details: `docs/matrix-api-scope.md`). (1) `POST /join` decides in this order: a member's re-join is an idempotent 200; a latest membership `ban` is `403 M_FORBIDDEN` "You are banned from this room" (whatever the rule); then the join rule: `public` joins, `invite` and `knock` need a pending invitation (`403 M_FORBIDDEN` "You are not invited to this room" otherwise), `restricted` / `knock_restricted` an invitation or membership of an `allow[]` room as before, and `private`, an unknown value and a malformed event are refused even with an invitation (strict room v10). A room WITHOUT an `m.room.join_rules` event is treated as `invite` (a Nebu / Synapse policy, not spec text). A failing read of the membership or the join rule state is a `500` (fail closed). The room creator's own join, room upgrade and auto-join are internal joins that bypass the rule by design (auto-join is operator policy and works in invite-only rooms, but it respects an existing ban); an Admin force-add goes through an invitation and cannot bypass a ban. `POST /rooms/{id}/invite` of a banned user and of a user who is already a member (a self-invite included) is `403 M_FORBIDDEN`; a kick, an Admin remove and a leave reject a pending invitation; a moderator needs a level strictly higher than the target's to kick or ban (room v10); an unban rejects a pending invitation; a new invitation re-arms an accepted or rejected one (before, a former member could never be re-invited). (2) `createRoom` writes the preset events after the alias and before `initial_state` (`private_chat` / `trusted_private_chat`: `invite`, `shared`, `can_join`; `public_chat`: `public`, `shared`, `forbidden`; without `preset` it is derived from `visibility`, default `private_chat`), and an `initial_state` entry for the same type wins over the preset event. A client that asks for a private room now gets one: Element's private rooms and DMs are invite-only. (3) `visibility: "public"` stores `rooms.visibility = 'public'` (audit row `room_visibility_changed`); it does not by itself make a room joinable and there is no room directory yet. (4) `topic` writes an `m.room.topic` event (`topic` plus `m.topic` text/plain, at most 1024 code points, Nebu policy). (5) `power_level_content_override` is merged shallowly over the default levels (creator at 100); the room-wide `events_default` / `invite` Element sends for Spaces are enforced now, a per-type `events` map is stored but not enforced (follow-up `eq`); power levels cannot be changed after creation, so a restrictive override is permanent. `name`, `topic` and the derived alias are stamped strictly after `initial_state`.

*New 400s clients can see on `createRoom`* (fixed messages, a rejected request creates nothing): `preset` / `visibility` of the wrong type `M_BAD_JSON`, an unknown value `M_INVALID_PARAM`; `topic` null / non-string / NUL `M_BAD_JSON`, over 1024 code points `M_INVALID_PARAM` (the same content rule applies to `initial_state` and `PUT .../state/m.room.topic`, `m.topic` text bodies are capped at 4096); `power_level_content_override` that is not an object, holds a JSON null, a non-integer or out-of-range value or an invalid user id `M_BAD_JSON`; an override that leaves the creator unable to set the initial state `M_INVALID_ROOM_STATE`.

*Existing rooms are NOT backfilled.* No event is written into existing rooms: a guess would have to infer what each room was meant to be. A room WITHOUT any `m.room.join_rules` event (every room created before this story unless its `initial_state` set one) is invite-only now, which is the intended state of every private room, DM, private Space and personal room. Rooms that were meant to be public (Element "public room" creates, Admin "Public" rooms, public Spaces created without a join rule) lose their open join until a member with power level 50 or more (the creator has 100) restores it: in Element Room settings -> Security & Privacy -> Access, or by a `PUT .../state/m.room.join_rules` with `{"join_rule": "public"}`, or invites the users. The Admin "Visibility" toggle only flips the label (follow-up `et`). Users who opted out of an auto-join room (they left it) stay out as before; a user who is no longer a member of an invite-only room, an opted-out auto-join user included, needs a new invitation to come back (public rooms are open). Two read-only queries for the operator (run with a read-only role; both were checked against a throwaway database inside a rolled-back transaction with fixture rows):

*Q1: rooms without any join rule* (the rooms that are invite-only after the upgrade; a second query lists the rooms whose join rule content is a JSON STRING holding the JSON, a legacy double encoding that the server reads as the rule it holds; `rooms.creator_user_id` is not populated by the server, so the sender of `m.room.create` is used; `has_history_visibility` is true for Element private rooms, which write the event, and false for Element public rooms; auto-join rooms show up as well and stay joinable for new users through the auto-join bypass). Review the public-looking ones and set `m.room.join_rules` to `public` where public access was intended.

```sql
SELECT r.room_id,
       r.visibility,
       r.room_type,
       COALESCE(r.creator_user_id,
                (SELECT c.sender FROM events c
                  WHERE c.room_id = r.room_id AND c.event_type = 'm.room.create'
                  ORDER BY c.origin_server_ts LIMIT 1)) AS creator_user_id,
       (SELECT count(*) FROM room_members m
         WHERE m.room_id = r.room_id AND m.left_at IS NULL) AS members,
       EXISTS (SELECT 1 FROM events h
                WHERE h.room_id = r.room_id AND h.event_type = 'm.room.history_visibility'
                  AND h.state_key = '') AS has_history_visibility
FROM rooms r
WHERE r.status = 'active'
  AND NOT EXISTS (SELECT 1 FROM events j
                   WHERE j.room_id = r.room_id AND j.event_type = 'm.room.join_rules'
                     AND j.state_key = '')
ORDER BY r.created_at, r.room_id;
```

Q1b, the double-encoded join rules (`jsonb_typeof(content) = 'string'`; checked inside a rolled-back transaction with a fixture row):

```sql
SELECT r.room_id, r.visibility, j.content #>> '{}' AS stored_text
FROM rooms r
JOIN LATERAL (SELECT e.content
                FROM events e
               WHERE e.room_id = r.room_id AND e.event_type = 'm.room.join_rules' AND e.state_key = ''
               ORDER BY e.origin_server_ts DESC LIMIT 1) j ON true
WHERE jsonb_typeof(j.content) = 'string'
ORDER BY r.created_at, r.room_id;
```

*Q3: pending invitations held by current members* (before this story an invitation row of a user who had joined stayed pending and could be re-armed by a self-invite; a pending invitation of a CURRENT member should not exist: the next `POST /join` of that member closes it, and a leave, a kick and an unban reject it now; list them and close the leftovers with an `UPDATE room_invitations SET accepted_at = <now ms> WHERE ...` for the listed pairs if you want them gone; checked inside a rolled-back transaction with a fixture row):

```sql
SELECT i.room_id, i.invitee_id, i.inviter_id, i.invited_at
FROM room_invitations i
JOIN room_members m
  ON m.room_id = i.room_id AND m.user_id = i.invitee_id AND m.left_at IS NULL
WHERE i.accepted_at IS NULL AND i.rejected_at IS NULL
ORDER BY i.room_id, i.invitee_id;
```

*Q2: incident review: joins without an invitation* (`m.room.member` `join` events of a user who is not the room creator, in rooms that are not `is_auto_join`, with no `room_invitations` row for the room and the user: such a join could only have happened through the old open join; legitimate for rooms that were meant to be public, suspicious for private rooms and DMs). Limits: `room_invitations` has one invitation row per (room, user) and a later re-invite overwrites it, so a row proves an invitation existed at some time, not that it preceded the join; an Admin force-add writes an invitation row (so it does not show up); joins from before invitations were tracked cannot be told apart; a user who joined through an `allow[]` Space of a `restricted` room shows up although the join was legitimate.

```sql
WITH joins AS (
  SELECT DISTINCT ON (e.room_id, e.state_key)
         e.room_id, e.state_key AS user_id, e.origin_server_ts
  FROM events e
  WHERE e.event_type = 'm.room.member'
    AND CASE WHEN jsonb_typeof(e.content) = 'object' THEN e.content ->> 'membership'
             ELSE ((e.content #>> '{}')::jsonb) ->> 'membership' END = 'join'
  ORDER BY e.room_id, e.state_key, e.origin_server_ts
)
SELECT j.room_id,
       r.visibility,
       COALESCE(r.creator_user_id,
                (SELECT c.sender FROM events c
                  WHERE c.room_id = r.room_id AND c.event_type = 'm.room.create'
                  ORDER BY c.origin_server_ts LIMIT 1)) AS creator_user_id,
       j.user_id AS joined_user,
       j.origin_server_ts AS first_join_ts
FROM joins j
JOIN rooms r ON r.room_id = j.room_id
WHERE NOT r.is_auto_join
  AND j.user_id IS DISTINCT FROM COALESCE(r.creator_user_id,
                (SELECT c.sender FROM events c
                  WHERE c.room_id = r.room_id AND c.event_type = 'm.room.create'
                  ORDER BY c.origin_server_ts LIMIT 1))
  AND NOT EXISTS (SELECT 1 FROM room_invitations i
                   WHERE i.room_id = j.room_id AND i.invitee_id = j.user_id)
ORDER BY j.room_id, j.origin_server_ts;
```

**`createRoom` invites, DMs and the shared invite path (story create-room-invites-direct, follow-up `eb`). Behaviour change, no migration.**

*What clients can see.* `createRoom` now processes `invite`, `invite_3pid` and `is_direct` (before, the keys were silently ignored: a DM or a private room was created empty, and since the join rule is enforced nobody could enter it). Each invitee gets a pending invitation and a signed `m.room.member` invite event in the timeline (`{"membership": "invite"}`, plus `"is_direct": true` when the request has `is_direct: true`, as the spec requires for DMs); `POST /rooms/{roomId}/invite` writes the same event and follows the same rules, so invite events now appear in the room timeline and `m.invited_member_count` is correct (Element's duplicate-DM check and its "local room" wait read them). With the `trusted_private_chat` preset (Element's one-to-one DM) every invitee gets the creator's power level: the DM partners are at level 100, permanently (neither can kick or ban the other, the creator cannot revoke a pending invitation; follow-ups `eq`, `fb`). An override `users` map replaces the invitee levels. Story sync-membership-partition replaced the interim guard of this story: the invitee sees the invitation (and the DM) in Element in `rooms.invite`, and a room the user is only invited to is no longer delivered in `rooms.join` (RELEASE GATE above: `ev` and `ez` are closed, the gate is now `ey`).

*New 4xx answers* (fixed messages, no client value echoed, a rejected `createRoom` creates nothing and is all-or-nothing). `createRoom`: `invite` or `invite_3pid` of the wrong type, a non-string entry or a malformed `invite_3pid` item `M_BAD_JSON`, a present non-boolean `is_direct` `M_BAD_JSON`; more than 50 entries (Nebu policy), a malformed user id or the creator's own id `M_INVALID_PARAM`; a user of another server `M_FORBIDDEN` (403, this server does not federate); an unknown or deactivated local user `M_NOT_FOUND` (404, one text and one body for both; the invitee must already have a `users` row, so a colleague who never logged in cannot be invited yet, and no row is ever created for an invitee); a well-shaped `invite_3pid` item `M_THREEPID_DENIED` (403, no identity server); an `invite` level that the creator cannot reach `M_INVALID_ROOM_STATE`. `POST /rooms/{roomId}/invite`: the former 500s are gone: a missing, non-string, malformed, foreign, unknown or deactivated `user_id` and the 3pid form used to end in a constraint violation (`500 M_UNKNOWN`); now `M_BAD_JSON` / `M_MISSING_PARAM` / `M_INVALID_PARAM` (400), `M_NOT_JSON` for a body that is not JSON, `M_FORBIDDEN`, `M_NOT_FOUND` and `M_THREEPID_DENIED` as above; `reason` is accepted and ignored (a known deviation, follow-up `fa`). A step 8 failure (an invitation row or event that cannot be written) is a `500` and the half-created room is cleaned up, now including its `room_invitations` rows.

*A trusted DM is co-owned.* In a `trusted_private_chat` room (Element's one-to-one DM) the partner is at level 100 like the creator from the moment the room is created (even if the partner never joins), and that is permanent (no power level route, no revoke of a pending invitation: follow-ups `eq`, `fb`): the partner can change every state event of the room (join rule, history visibility, name, topic, avatar, tombstone) and invite others, while neither can kick or ban the other. This is the spec ("all invitees are given the same power level as the room creator") and Synapse's behaviour, not an escalation; acknowledge it in the release notes.

*Existing invitations are NOT backfilled.* A pending invitation created before this story (including those of a room upgrade) has no invite member event and is not backfilled: it stays joinable, but the room timeline does not show it and `get_member_membership` does not answer `invite` for it; a repeated `POST /invite` for such a user writes the event (it counts as not yet invited). `ev` (closed by story sync-membership-partition) copes with both kinds: a row-only invitation gets a synthesized own member event in `invite_state` (follow-up `fb`). Nothing to run for the operator; the Q-queries above are unchanged.

**Event size limits (story event-size-limit, follow-up `ep`).** Behaviour change, no migration, no new setting. *What clients can see.* `PUT /rooms/{roomId}/state/{eventType}/{stateKey}`, `PUT /rooms/{roomId}/send/{eventType}/{txnId}` and `POST /createRoom` refuse, BEFORE anything is persisted, an event whose canonical JSON (the stored event plus its `event_id` and `signatures`, 171 bytes) is above 65536 bytes (`413 M_TOO_LARGE` "Event exceeds the maximum size of 65536 bytes") and a `type` ("Event type exceeds 255 bytes") or `state_key` ("State key exceeds 255 bytes") above 255 bytes (counted in bytes after URL decoding, not code points). `createRoom` decides before the room exists and names the source ("creation_content makes the m.room.create event exceed ...", "power_level_content_override makes the m.room.power_levels event exceed ...", "An initial_state event exceeds ..."): a refused request creates nothing (it still spends its rate-limit units). The status code is a Nebu decision with Synapse parity (the spec names no code for the size limit; `400 M_TOO_LARGE` would be the table-conformant alternative, clients act on the errcode); the accounting is a Nebu interpretation (no reserve for the PDU keys, Nebu does not federate). A request body above the 1 MB parser cap on any `/_matrix` route now gets the same Matrix envelope (`413 M_TOO_LARGE` "Request body is too large", `application/json`, CORS headers) instead of an empty 413. Element's normal events are far below the limit (the largest, `m.room.create` / `m.room.power_levels` of createRoom and Space state, are a few KB; the story's e2e run B counts the 413s of a full Element run and lists the largest real events); a message pasted above 64 KiB is refused, as on Synapse.

*User ids are bounded to 255 bytes (D12).* A Matrix user id is at most 255 bytes, but the localpart comes from an IdP claim and was never bounded. `Nebu.Matrix.UserId.from_claims/2` now keeps an id of at most 254 bytes exactly as before (nobody with a normal claim gets a new identity); every id that would be 255 bytes or more becomes a truncated prefix of the localpart, `-` and 16 hex characters of the SHA-256 of the full localpart, which makes the hashed id EXACTLY 255 bytes (deterministic, so login, `OidcPlug`, SSO and the Admin agree). The two forms are disjoint by length: a natural id never has 255 bytes and a hashed id always has, so hashed ids and natural ids no longer share a namespace by construction (no claim a user can choose equals the hashed id of another user's long claim). An account created before this release with an id of 255 bytes or more gets a NEW id at its next login (its old rows stay; its session is answered `403 M_FORBIDDEN` "Your user id exceeds 255 bytes: sign in again" on these three routes until then, and an Admin can still remove such an id from a room): the query Q-uid below lists such accounts (expected none; run it BEFORE the upgrade, because afterwards it also lists the legitimate hashed ids, which have exactly 255 bytes). A server name above 235 bytes leaves less than 18 bytes of the id for the localpart: the server REFUSES TO START with a message that names the byte size of `NEBU_SERVER_NAME` (use a shorter name).

*Existing events are NOT changed or deleted.* No migration, no backfill: events written before this release stay exactly as stored and are delivered as before, and the read-side budgets stay as defence in depth for them (64 KiB per optional stripped event and 8 MiB per `rooms.invite` response; `m.room.create` above 64 KiB is reduced). A legacy oversized STATE event keeps travelling as the `unsigned.prev_content` of its slot's next event, so it is gone from the current state and from `prev_content` after TWO new writes of that slot (a room admin: Element room settings, or two `PUT .../state` with a normal content); a legacy oversized MESSAGE event stays (no redaction, follow-up `fl`). `upgrade_room` does not copy a legacy oversized state event (one warning with the counts "skipped N, reduced M", no type or content) and copies `m.room.join_rules`, `m.room.history_visibility` and `m.room.guest_access` of that size in a reduced form that holds only their spec key (an unknown or malformed value becomes `private` / `joined` / `forbidden`; `allow` of a restricted join rule is dropped: invitations only), so the new room is never more open than the old one.

*Q-size: events above the size limits (candidates)*: read-only, a sequential scan of `events` (run it off-peak, with a read-only role). It is an UPPER-BOUND estimate: `content::text` of JSONB adds a space after every `:` and `,` and a double-encoded JSONB string adds escapes, so every event above the limit is listed, plus some just below it (`268` is the fixed canonical envelope without the four string values, 97 bytes, plus `event_id` and `signatures`, 171; escapes inside the identifiers are not counted). Checked inside a rolled-back transaction with a fixture row of 70 000 bytes, one of 1 000 bytes, one with a 256-byte `state_key` and tiny content and one with a 256-byte `event_type`: all but the 1 000-byte row are listed. Nothing needs to be done for the rows it lists.

```sql
SELECT e.room_id, e.event_id, e.event_type,
       e.state_key IS NOT NULL AS is_state,
       e.origin_server_ts,
       octet_length(e.content::text) AS content_text_bytes,
       octet_length(e.event_type) AS type_bytes,
       octet_length(coalesce(e.state_key, '')) AS state_key_bytes
FROM events e
WHERE octet_length(e.content::text) + octet_length(e.event_type) + octet_length(coalesce(e.state_key, ''))
      + octet_length(e.sender) + octet_length(e.room_id) + 268 > 65536
   OR octet_length(e.event_type) > 255
   OR octet_length(coalesce(e.state_key, '')) > 255
ORDER BY e.room_id, e.origin_server_ts;
```

*Q-uid: accounts whose user id has 255 bytes or more*: expected none; such an account gets a new id at its next login (it has to sign in again, D12; a new id is hashed to exactly 255 bytes, so run this query before the upgrade, afterwards a hit can be a legitimate hashed id). Checked inside a rolled-back transaction with fixture rows of 256 and 255 bytes (listed) and one of 254 bytes (not listed).

```sql
SELECT user_id, octet_length(user_id) FROM users WHERE octet_length(user_id) >= 255 ORDER BY 1;
```

**Redaction and the room-process state writer (story state-writer-redaction, follow-ups `fw`, `fv`, `fz`, `fx`).** Behaviour change, ONE migration (000051). *What clients can see.* Element's message options > "Remove" and the moderator's "Remove recent messages" work: `PUT /_matrix/client/v3/rooms/{roomId}/redact/{eventId}/{txnId}` (and `m.room.redaction` on `/send`) is decided and written by the room process, an own message needs `events["m.room.redaction"]` (default `events_default`, 0), another user's message additionally the `redact` level (default 50). Every client read path (`/messages`, `/event`, `/relations`, `/sync` timelines, the leave window, the thread roots, `/initialSync`) serves a redacted message with `content: {}` and `unsigned.redacted_because`; search and relation children exclude it. Changed answers: a `/send` redaction below the `redact` level is `403` (it was stored as sent and delivered), state events and redactions cannot be redacted (`403`, `ga`), PUT state into an archived room is `404`, an unknown room is `403` without a `rooms` row, the upgrade needs the tombstone level and at least 100, a createRoom `initial_state` entry with another user's state key is `400`. *What is kept in the database, and why.* "Remove" HIDES a message, it does not erase it: the original event row is never changed (Compliance Mode: server-readable content for auditing and eDiscovery, ADR-023; the GDPR runbook: the event timeline is an append-only log; ADR-030: redaction is not a deletion tool); "redacted" is derived at read time from the redaction rows (`events.redacts`). A retention / purge policy for redacted content, a compliance viewer and the media of redacted messages are open owner decisions (`gb`). *Legacy rows and operator query **Q-rd**.* Redactions written through `/send` before this story were never authorised: their `redacts` column is NULL, they are never applied and are served without `content.redacts` (`gd`). **Q-rd** lists them; run it first in a rolled-back transaction with fixture rows:

```sql
SELECT event_id, room_id, sender, origin_server_ts
FROM events
WHERE event_type = 'm.room.redaction' AND redacts IS NULL
ORDER BY origin_server_ts;
```

*Migration 000051* adds the nullable column `events.redacts` and the partial index `events_redacts_idx (redacts, origin_server_ts, event_id) WHERE redacts IS NOT NULL` (the read-time lookup has no `room_id` predicate: event ids are global content hashes; it reads at most ONE redaction per target, the earliest): no backfill, no data change, rolling-deploy safe (old nodes neither read nor write the column; an old node's `/send` redaction writes NULL and stays unapplied). *The locks:* every migration runs inside one transaction, where `CONCURRENTLY` is not available. The `ALTER TABLE events ADD COLUMN` takes an ACCESS EXCLUSIVE lock on `events`, the largest table, and holds it until the commit, so it covers the whole scan of the plain `CREATE INDEX` (which alone would take a SHARE lock): READS AND WRITES on `events` wait, the duration grows with the table size and there is no lock timeout. Run the migration in a maintenance window, or pre-create both by hand before deploying, outside a transaction: (1) `ALTER TABLE events ADD COLUMN IF NOT EXISTS redacts TEXT` (instant: catalog-only, a brief ACCESS EXCLUSIVE lock), then (2) `CREATE INDEX CONCURRENTLY IF NOT EXISTS events_redacts_idx ON events (redacts, origin_server_ts, event_id) WHERE redacts IS NOT NULL`; the migration is then a no-op: run it when no long transaction is open on `events` (its no-op ALTER still needs a brief ACCESS EXCLUSIVE lock). *Rollback re-exposes removed messages:* the down step of 000051 drops `events.redacts`, so every applied redaction becomes a never-applied legacy row and every removed message is readable again for the room's members (the down step is not refused: decide before rolling back); rolling back only the application image (old code without the pruning, the column kept) re-exposes removed messages too. *Edits of a removed message stay served* (`/messages`, `/sync`, `/relations`; the spec does not redact edits, Element hides them in its timeline only); they are excluded from search. A redaction of an already removed message returns the existing redaction (no second row). *Upgrade:* a tombstone write whose old room does not answer is `503` and keeps the started new room: on 503, retry the upgrade; a left orphan room is cleaned up by archiving it in the Admin UI.

**Per-room event positions, migration 000053 (story events-room-position, follow-up `fc`, story 1 of 2; the reader is story sync-stream-position).** Write path only, no API change. The migration adds the per-room counter `rooms.event_pos BIGINT NOT NULL DEFAULT 0`, the nullable column `events.room_pos BIGINT`, the unique partial index `events_room_pos_idx (room_id, room_pos) WHERE room_pos IS NOT NULL` and a `BEFORE INSERT ... FOR EACH ROW` trigger on `events` (`events_room_pos_trigger`) that draws the position by updating the room's `rooms` row: the row lock lives until the inserting transaction ends, so the writes of one room are serialised in the database and the position order of a room is its commit order, for every writer (an old node during a rolling deploy included); rooms do not block each other. The trigger is a documented exception to ADR-018 (SQL inline in the caller). No backfill: existing events keep `room_pos` NULL and the first new event of an existing room gets 1. *Cost:* one extra `rooms` row update per inserted event inside the same statement (HOT-eligible, no extra client statement); a standalone message insert now waits while another transaction holds the room's row (the archive / unarchive path, a room write transaction; their hold time is short but not bounded by `lock_timeout`, which only bounds their own waits); the insert itself has no lock timeout and fails only at the 15 s query timeout. `rooms` is updated once per event: HOT needs free space on the page and a moving xmin horizon, so watch `n_dead_tup` / `n_tup_hot_upd` of `rooms` (`pg_stat_user_tables`) and consider `ALTER TABLE rooms SET (fillfactor = 70)` (70-80) if the xmin horizon is held back (long transactions, replication slots). *Bulk inserts:* a bulk insert of many events of ONE room in ONE transaction or statement is O(n^2) (the repeated updates of one `rooms` row cannot be pruned before the commit; about 11 s for 10 000, measured); no current writer does it. A future importer must insert in batches of at most about 1 000 events per room per transaction, committing between batches, and must NOT disable the trigger table-wide (live writers would store NULL positions that are never delivered); a session-scoped `session_replication_role = replica` plus explicit stamping is the only safe variant (superuser only). *Rolling deploy:* an OLD node's membership change still locks the room row `FOR SHARE`, so two old-node membership transactions of the same room (only during a Horde handover with two room processes) can deadlock on the lock upgrade; PostgreSQL aborts one, it is rolled back and the client retries (rare and self-healing, gone once every node runs the new image). *The locks:* every migration runs inside one transaction, where `CONCURRENTLY` is not available; the two `ADD COLUMN`s are catalog-only, but the `ALTER TABLE events` holds an ACCESS EXCLUSIVE lock on `events` until the commit, so it covers the whole scan of the unique index build (the index stays empty, the build still scans the table): READS AND WRITES on `events` wait, the duration grows with the table size and there is no lock timeout. Run the migration in a maintenance window, or pre-create by hand before deploying, outside a transaction: (1) `ALTER TABLE events ADD COLUMN IF NOT EXISTS room_pos BIGINT;` (2) `ALTER TABLE rooms ADD COLUMN IF NOT EXISTS event_pos BIGINT NOT NULL DEFAULT 0;` (3) `CREATE UNIQUE INDEX CONCURRENTLY IF NOT EXISTS events_room_pos_idx ON events (room_id, room_pos) WHERE room_pos IS NOT NULL;` The migration is then a no-op except the trigger (a brief lock; the file is idempotent): run it when no long transaction is open on `events` or `rooms` (its no-op ALTERs and the trigger DDL still need a brief ACCESS EXCLUSIVE lock on both, and every new query on them queues behind it). A deadlock abort of the migration (against a live insert during the window) is harmless: the whole file rolls back, re-run it. A `CREATE UNIQUE INDEX CONCURRENTLY` that failed midway leaves an INVALID index that `IF NOT EXISTS` skips silently (uniqueness is then not enforced): check `SELECT indisvalid FROM pg_index WHERE indexrelid = 'events_room_pos_idx'::regclass`, and if it is false, `DROP INDEX CONCURRENTLY events_room_pos_idx` and run (3) again. *Rollback:* the down step drops the trigger, its function, the index and both columns (the positions are lost, the events stay); story sync-stream-position must be reverted first. Order: revert the migration of story sync-stream-position (`sync_room_cursors`, the next number) BEFORE this one, together with that story's code: this down drops `events.room_pos`, and dropping a column silently drops every index on it (`events_room_pos_idx`, the index of the position reads of story sync-stream-position), so a node still running that story would read without its index and without positions.

**GDPR erasure covers every per-user table, migration 000055 (story gdpr-erasure-global-data, follow-up `ck` closed).** Behaviour change of the erasure (`delete_user_keys`): in the same transaction it now also deletes the user's `account_data` (secret storage, push rules, `m.direct`), `cross_signing_keys`, `device_keys` / `device_one_time_keys` / `device_fallback_keys` and the other per-user tables (`forgotten_rooms`, `auto_join_opt_outs`, `read_receipts`, `uia_sessions`, `oauth_account_sessions`, `oauth_consent_requests`, `oauth_codes`), anonymises the profile (`Deleted User`, no avatar, `users.anonymized_at`), sets the PII columns of the `users` row (display name, avatar, email ciphertexts, `last_seen_at`, `deactivation_reason`) to NULL and sets `is_active = false`; the post-commit teardown also deletes the `devices` rows of legacy devices (display name, last IP). *The erasure is terminal:* every authentication gate (token validation, OAuth session issue, `/login`, the account pages, room invitations) treats a user with a `deletion_status` as deactivated, so an admin reactivation (`is_active = true`) does not revive an erased user, and `Profile.DB.upsert_profile/3` writes nothing for one (a login can never revert `Deleted User`); a bearer (an unbound raw IdP JWT included) that a node's provisioning cache (60 s TTL) already confirmed is still accepted on that node for up to 60 s, new requests included, the same bound as for an admin deactivation, and in that window it can write the tables without a guard (device keys, receipts, room account data, the lazy device row; the profile PUT, account data, cross-signing and the sync persist are refused): re-run the sweep afterwards (the eviction broadcast is follow-up `gn`). Reactivating an erased user through the admin function is refused and the admin user suggestions do not offer one. The display name and avatar ciphertexts were NOT crypto-shredded by the key deletion (they are encrypted with the server-wide `pii_encryption_key`): that is why they are NULLed. `AccountDataStore.put/3`, `CrossSigningKeyStore.put_keys/2` and the signature merge refuse a user whose erasure is under way or done (`{:error, :user_erased}`: the request answers `403 M_USER_DEACTIVATED`, nothing is stored), and the initial / fallback `/sync` persist writes no `sync_tokens` / `sync_room_cursors` row for such a user; its token statement and the profile upsert lock the user's `users` row `FOR SHARE` (an initial sync waits for an erasure in progress; initial syncs of active users do not block each other, but the lock is a row write: it dirties the `users` page). *Migration 000055* only replaces a row level security policy (`oauth_codes_delete`: the runtime role may also delete the codes of a user whose erasure is under way or done, never those of an active user), no table rewrite, no lock beyond the catalog change of the policy DDL. *Rollback:* the down step restores the 000041 policy; roll the code back together with it. The erasure now fails closed without the policy: it counts the `oauth_codes` rows left after its DELETE and, if any remain, rolls back with the step `oauth_codes_not_erased` in the `error_detail` of the `user_keys_deletion_attempted` audit row (every failing step of the erasure is named there as `step=<name>`, and in the log). *Privileges:* the erasure issues the first runtime `DELETE` on `account_data` and `cross_signing_keys` (migrations 000014 / 000015 carry no explicit `GRANT`, the runtime role of the dev docker setup has the privilege through default privileges, a single-role production database through ownership): verify once on a two-role database with `SELECT has_table_privilege('nebu_app', 'account_data', 'DELETE'), has_table_privilege('nebu_app', 'cross_signing_keys', 'DELETE')` (both must be true). *Cost:* the erasure deletes `read_receipts` rows by `user_id` without an index on that column (a scan of the table; the erasure is rare and the statement runs inside the erasure's transaction, which holds the user's locks: erase off-peak on a large instance). *Rolling deploy:* an erasure that runs on an OLD node still leaves the rows: run the sweep below after every node runs the new image. *Users erased before this release* keep those rows (a second erasure answers `:conflict`) and their `users` PII ciphertexts, and stay active: run the following one-off, idempotent sweep ONCE after the deploy (after migration 000055), as the operator (owner) role; it touches only users with `deletion_status = 'keys_deleted'`: it deletes the rows of the erasure's tables, the legacy `devices` rows (display name, last IP) and the other teardown tables (sessions, tokens, bindings, cursors, leases), anonymises the profile, NULLs the `users` PII columns and sets `is_active = false`. The sweep is also the retry path of an erasure whose best-effort post-commit session teardown failed (a warning in the log, `keys_deleted` answered): run it again for that user. Backups: erased data persists in backups within their retention (see the runbook):

```sql
-- gdpr-erasure-global-data: one-off sweep for users erased BEFORE this release (deletion_status = 'keys_deleted'). Run once after the deploy (after migration 000055)
-- as the operator (owner) role; idempotent (a second run changes nothing); it is also the RETRY path of a failed post-commit session teardown of an erasure.
-- Built from the same table list as the erasure (UserDeletion.erased_tables/0), plus the teardown tables, the profile and the users row.
-- In psql run it with `\set ON_ERROR_STOP on` first, so that a failing statement stops the run instead of leaving an aborted transaction.
BEGIN;
DELETE FROM uia_sessions WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM user_room_account_data WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM account_data WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM cross_signing_keys WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM device_keys WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM device_one_time_keys WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM device_fallback_keys WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM forgotten_rooms WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM auto_join_opt_outs WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM read_receipts WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM oauth_account_sessions WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM oauth_consent_requests WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM oauth_codes WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
-- the post-commit session teardown tables (a teardown that failed after the commit left them; the tokens are dead, the rows are not)
DELETE FROM sync_room_cursors WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM oauth_idp_refresh_leases WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM jwt_device_bindings WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM matrix_sessions WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM sessions WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM sync_tokens WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
DELETE FROM devices WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
UPDATE profiles SET displayname = 'Deleted User', avatar_url = NULL WHERE user_id IN (SELECT user_id FROM users WHERE deletion_status = 'keys_deleted');
UPDATE users SET anonymized_at = COALESCE(anonymized_at, keys_deleted_at), is_active = false, deactivated_at = COALESCE(deactivated_at, keys_deleted_at),
  display_name_encrypted = NULL, display_name_nonce = NULL, avatar_url_encrypted = NULL, avatar_url_nonce = NULL,
  email_encrypted = NULL, email_nonce = NULL, email_ephemeral_pub = NULL,
  last_seen_at = NULL, deactivation_reason = NULL
  WHERE deletion_status = 'keys_deleted';
COMMIT;
```

**`/sync` per-room stream positions, migration 000054 (story sync-stream-position, follow-up `fc` closed, story 2 of 2; needs migration 000053 of story events-room-position, ship both in one release).** Behaviour change of `GET /sync`, one migration. *What clients see:* an incremental `/sync` continues from per-room positions instead of a timestamp anchor, so no event, invitation or leave is lost to late commits, same-millisecond events, a createRoom chain stamped ahead of the clock or clock skew between nodes; a room with more than 20 new events carries its newest 20 with `limited: true` and a real `/messages` `prev_batch`; a retry with the previous `next_batch` (a lost response) continues incrementally. *After the update each client does one full sync* (an initial-shaped answer, once): every `sync_tokens` row of the timestamp era has `stream_version` 0 and a token without the `s2_` prefix is never read as positions, it falls back. *The migration* creates the table `sync_room_cursors` (one row per user, device and partition room; `ON DELETE CASCADE` from `sync_tokens`, so logout, device deletion, deactivation and GDPR erasure remove the rows with the token row; grants for `nebu_app`) and adds five `sync_tokens` columns with constant defaults (`stream_version SMALLINT NOT NULL DEFAULT 0`, `generation BIGINT NOT NULL DEFAULT 0`, `prev_since_token`, `prev_account_data_pos`, `prev_cross_signing_pos`, the last three nullable): catalog-only, no rewrite, a brief ACCESS EXCLUSIVE lock on `sync_tokens` (every `/sync` waits for it for that moment); there is no lock on `events`. No maintenance window is needed (000053 of the same release does need one, see above). *Mixed-version window (rolling deploy):* an old node continues a new node's `s2_` token with its timestamp anchor (`last_event_id` is still written for that: the old behaviour, with the old `fc` losses) and writes an old-format token (its upsert leaves the new columns alone); a new node reads that token as a fallback (the `s2_` prefix check, whatever `stream_version` says), never as positions: a crossing costs the client one initial-shaped answer, never a misread. *Cost:* an incremental sync reads one head statement for all rooms and one timeline per room that moved (a quiet room costs nothing; no anchor read), plus the guarded write of the token row and the changed cursor rows; an initial sync adds the head statement and one bulk cursor write. Storage: one small row per device and partition room. *Rollback:* the down step drops the table, then the five columns; every client falls back once again (the rolled-back code does not understand the `s2_` tokens). Revert 000054 BEFORE 000053: a down of 000053 drops `events.room_pos`, and with it, silently, the index every position read of this story uses.

**Room membership state (story membership-state-model, follow-ups `fb`, `fl`).** Behaviour change, no migration. *What clients can see.* The member state is read from the signed member events in the database (`Room.DB.member_state_slice/2`, the latest member event of every user with the tie order of the `/sync` partition and the join decision): the "Invited" section of Element's member list and the "Banned users" list of the room settings (with the `reason` and who banned) are right after a reload, a new login or "Clear cache and reload", not only while the invite / ban event is among the last 20 timeline events. The initial `/sync`, `GET /rooms/{roomId}/members` (`membership` / `not_membership`, real event ids, `unsigned`) and `/initialSync` serve the same slots; the incremental `/sync` keeps the joined slice of the room process (`gg`). `/members` and `/initialSync` of an unknown room id answer `403` and no longer create a `rooms` row. *Who sees what.* Only joined users: every joined member sees the banned, kicked, invited and left user ids, the senders and the stored `reason` (room state); invitees, users who left and non-members get `403`. Nothing of it is logged at INFO or above (the slice, a `reason`, a displayname are never logged; a failing read logs the room id and the error class only). *Bound and cost.* Member slots other than `join` are capped at 10 000 per room per response (invite, then ban, knock, leave; newest first); two more statements per joined room of an initial `/sync` (`SET LOCAL` + the slice inside `BEGIN` / `COMMIT`). Operator query **Q-ms** lists the rooms above the cap (read-only, a full scan of the member events: run it off-peak, with a read-only role; verified in a rolled-back transaction with fixture rows; PostgreSQL 16 or later for `pg_input_is_valid`):

```sql
SELECT room_id, count(*) AS non_join_slots
FROM (
  SELECT DISTINCT ON (room_id, state_key) room_id, state_key, membership
  FROM (
    SELECT room_id, state_key, origin_server_ts, event_id,
           CASE jsonb_typeof(content)
             WHEN 'object' THEN content->>'membership'
             WHEN 'string' THEN CASE WHEN pg_input_is_valid(content #>> '{}', 'jsonb') THEN ((content #>> '{}')::jsonb)->>'membership' END
           END AS membership
    FROM events
    WHERE event_type = 'm.room.member' AND state_key IS NOT NULL
  ) member_events
  ORDER BY room_id, state_key, origin_server_ts DESC,
           CASE membership WHEN 'ban' THEN 0 WHEN 'leave' THEN 1 WHEN 'invite' THEN 2 WHEN 'knock' THEN 3 WHEN 'join' THEN 4 ELSE 1 END,
           event_id DESC
) latest
WHERE membership IS DISTINCT FROM 'join'
GROUP BY room_id
HAVING count(*) > 10000
ORDER BY non_join_slots DESC;
```

*Load bound (security cycle 1, Kassandra M-1).* The slice reads every member event the room ever had: its cost is O(member events of the room), not O(users) (membership churn grows it). Three bounds: (1) the per-user tier `members_read` (60 per minute, burst 30; `NEBU_RATE_LIMIT_MEMBERS_READ_PER_MIN` / `NEBU_RATE_LIMIT_MEMBERS_READ_BURST`, empty = the default, a broken pair falls back and is warned at boot; per node; `NEBU_RATE_LIMIT_DISABLED=true` turns it off) is charged first, before the room is resolved, for `GET /rooms/{roomId}/members` and `GET /rooms/{roomId}/initialSync` (a `429 M_LIMIT_EXCEEDED`; a divergence from the spec (no rate limit listed)); the initial `/sync` is not charged; (2) the slice (and, for `/members` and `/initialSync`, the predecessor lookup of their state events) runs with `SET LOCAL statement_timeout = '2s'`; (3) slice reads are limited to 3 concurrent per node (`NEBU_MEMBER_SLICE_MAX_CONCURRENCY`, a strictly positive integer, else ignored with a boot warning; node-local, like the rate tiers: N nodes allow N x the limit; not turned off by `NEBU_RATE_LIMIT_DISABLED`), so they hold at most 3 of the 10 pool connections of a node, whatever route triggers them. A read that meets the timeout, loses its pool connection or finds the limit full (a `/sync` read waits up to 1 s for a slot) is answered on `/members` and `/initialSync` with `503 M_UNAVAILABLE` "The member list is temporarily unavailable, try again" (a value-free warning with the room id), never a degraded answer; on the `/sync` paths (initial, garbage `since`, `full_state=true`) only that room is degraded: member state of this room is joined-only until the client's next initial or `full_state` sync, or a `/members` call (lazy loading); a new member event refreshes only that member's slot (completeness gap, not a leak; one value-free warning), the rest of the response is unchanged (`gg`). What bounds the member-state SLICE of `/sync`, which `members_read` does not charge: the node-wide limit and the 2 s timeout; the lenient predecessor pass of `/sync` (one index probe per state slot) is neither gated nor timed (`gg`). The gate admits exactly: a supervised process monitors every reader and hands a freed slot to the oldest waiter (FIFO; at most 4 x the limit wait, the others are refused at once); a reader killed mid-query frees its slot at once while its database backend may still run up to the 2 s timeout, so "at most 3 of the 10 pool connections" holds for the pool checkouts, briefly not for the backends. Sizing: keep `NEBU_MEMBER_SLICE_MAX_CONCURRENCY` well below the pool size (10; a boot warning names a value at or above it); a login burst degrades rooms rather than queueing for long; raise it carefully, together with the pool. Every other failure of the read is a `500`. A known stopped room is started only for a joined member (the caller's latest member event is read first): a never-member gets the `403` without a start. Operator query **Q-ms2** lists the 20 rooms with the most member events (history included), the rooms whose member reads are the most expensive (a full scan of the member events: run it off-peak, with a read-only role; verified in a rolled-back transaction with fixture rows):

```sql
SELECT room_id, count(*) AS member_events
FROM events
WHERE event_type = 'm.room.member' AND state_key IS NOT NULL
GROUP BY room_id
ORDER BY member_events DESC
LIMIT 20;
```

*Room upgrades.* The upgrade invites the old joined members with real invite events in the upgrader's name (plus the rows, `is_direct` carried from the member's own invite in the old room); existing row-only invitations stay valid (they get a synthesized `invite_state` entry as before); a new-room process that dies during the invitations leaves the remaining old members uninvited (the upgrade answers `200`, ONE warning names the number skipped; invite them again from the new room); no migration.

**Power levels (story power-levels-enforcement, follow-ups `eq`, `er`, `fr`).** Behaviour change, no migration. *What clients can see.* `PUT /_matrix/client/v3/rooms/{roomId}/state/m.room.power_levels` works (before it was `403`): Element's Room settings > Roles & Permissions and the composer commands `/op` and `/deop` work. The change follows the Matrix room version 10 rules (nobody grants more than he has, nobody changes a level at or above his own, only integers are stored) and is decided and written in the room process in one transaction, audited as `room_power_levels_changed`. Changed answers: the `events` map is enforced (a send needs `events[type]` else `events_default`, a state PUT needs `events[type]` else `state_default`: before, `events` was shown and ignored), a state key that starts with `@` must be the sender's own id (`403`), an `initial_state` `m.room.power_levels` entry is applied (a replacement at step 6), new rooms get the default `events` map (non-spec, Synapse-derived), `POST /rooms/{roomId}/upgrade` carries the levels and needs the upgrader at the highest level of the room (`403` otherwise). The PUT of this type is charged to the `moderation` tier (30 per minute, burst 60; a divergence from the spec's Rate-limited: No). *Legacy rooms (`fy`).* Rooms created before this story keep their content: `events` is empty there, so `state_default` (50) governs the levels, the history visibility and the tombstone, and a room whose stored content is `{}` cannot be changed at all. *Operator query **Q-pl**.* Lists the rooms whose stored content is not a JSON object (unparsable, `null`, an array or another JSON type), has a non-integer or out-of-range value (outside +-(2^53 - 1); checked in the seven integer keys and in the values of `users`, `events` and `notifications`), no content at all, or no `events["m.room.power_levels"]`; run it first in a rolled-back transaction with fixture rows (the guards keep one broken row from aborting the query; needs PostgreSQL 16 or later for `pg_input_is_valid`):

```sql
WITH pl AS (
  SELECT r.room_id,
         CASE
           WHEN r.power_levels_json IS NULL OR btrim(r.power_levels_json) = '' THEN '{}'::jsonb
           WHEN NOT pg_input_is_valid(r.power_levels_json, 'jsonb') THEN NULL
           WHEN jsonb_typeof(r.power_levels_json::jsonb) = 'object' THEN r.power_levels_json::jsonb
         END AS c
  FROM rooms r
),
vals AS (
  SELECT pl.room_id, kv.value
  FROM pl CROSS JOIN LATERAL jsonb_each(pl.c) kv
  WHERE kv.key IN ('ban', 'kick', 'invite', 'redact', 'state_default', 'events_default', 'users_default')
  UNION ALL
  SELECT pl.room_id, kv.value
  FROM pl
  CROSS JOIN (VALUES ('users'), ('events'), ('notifications')) m(k)
  CROSS JOIN LATERAL jsonb_each(CASE WHEN jsonb_typeof(pl.c -> m.k) = 'object' THEN pl.c -> m.k ELSE '{}'::jsonb END) kv
),
odd AS (
  SELECT DISTINCT room_id FROM vals
  WHERE CASE
          WHEN jsonb_typeof(value) <> 'number' THEN true
          WHEN value::text !~ '^-?[0-9]+$' THEN true
          ELSE abs((value::text)::numeric) > 9007199254740991
        END
)
SELECT pl.room_id,
       CASE
         WHEN pl.c IS NULL THEN 'not a JSON object'
         WHEN pl.c = '{}'::jsonb THEN 'no content'
         WHEN pl.room_id IN (SELECT room_id FROM odd) THEN 'non-integer value'
         ELSE 'no events[m.room.power_levels]'
       END AS reason
FROM pl
WHERE pl.c IS NULL
   OR pl.c = '{}'::jsonb
   OR pl.room_id IN (SELECT room_id FROM odd)
   OR NOT jsonb_exists(CASE WHEN jsonb_typeof(pl.c -> 'events') = 'object' THEN pl.c -> 'events' ELSE '{}'::jsonb END, 'm.room.power_levels')
ORDER BY pl.room_id;
```

**Room moderation: kick, ban, unban (story moderation-routes-atomic-ban, follow-ups `ex`, `ew`).** Behaviour change, no migration. *What clients can see.* `POST /_matrix/client/v3/rooms/{roomId}/kick`, `/ban` and `/unban` answer `200 {}` now (before, they were `404 M_UNRECOGNIZED`: nobody could ban, kick or unban through the API; Element's "Remove from room", "Ban", "Unban" and "Disinvite" and the composer commands `/remove`, `/ban` and `/unban` work). A ban is enforced on join in every room; a kick removes a member, and a kick of a pending invitee withdraws the invitation ("Disinvite": the invitation leaves his `/sync` and his `POST /join` is `403`). Changed answers: a kick of a user who is neither a member nor an invitee is `403 M_FORBIDDEN` (it was an internal `404`), an unban needs the `kick` level as well as the `ban` level and only a banned user can be unbanned (`403` otherwise), and `POST /rooms/{roomId}/upgrade` carries the bans of the old room into the new room (as new ban events in the upgrader's name: a banned user can no longer join a copied `public` room; the power levels are carried (story power-levels-enforcement), follow-up `fr`). The scope doc lists every rule, the fixed texts and the labels of the Nebu choices.

*Limit and audit.* A fourth per-user token bucket, the `moderation` tier (30 per minute, burst 60, per node, one unit per request of the three routes, charged first), answers `429 M_LIMIT_EXCEEDED`; it is a divergence from the spec, which flags all three endpoints "Rate-limited: No". Tuning: `NEBU_RATE_LIMIT_MODERATION_PER_MIN` and `NEBU_RATE_LIMIT_MODERATION_BURST` (strictly positive integers, anything else keeps the default; `NEBU_RATE_LIMIT_DISABLED=true` disables the tier like the other three). Audit actions (best effort, written after a committed change, metadata `user_id` only, plus `invitation_revoked` for a kick; the `reason` is never copied): `room_member_kicked`, `room_member_banned`, `room_member_unbanned`. A refusal and the repeat of a ban write no row; the `room_upgraded` row gains `bans_carried`.

*Guarantee.* Every change that a ban can race (kick, ban, unban, the invite event, the decline, the join) is decided and written inside the room process, stamped after the user's latest member event, and committed in ONE database transaction: a failing write answers `500` and changes nothing. A room that does not answer is `503 M_UNAVAILABLE` (not a spec errcode): the change may or may not have been applied, retry it (a repeated ban is idempotent).

*Element's "Banned users" list.* Element builds it from the room state, and the state of `/sync`, `/members` and `/initialSync` lists only joined members (follow-up `fb`, story 2): after a fresh initial sync the list is empty although the bans are enforced. Unban through the member's profile in the timeline, `/unban <user id>` in the composer or the API.

*Q-half: banned users that are still in the member set* (an ACTIVE `room_members` row whose LATEST member event is a `ban`: typically legacy leftovers of the old two-step ban, which could fail between the ban event and the member removal; other old non-transactional writers could leave the same shape, so treat every row as a half state, whatever its origin; a kick of such a user is refused with "unban them instead"). Read-only: one pass over `room_members` with an index range scan of the user's member events per ACTIVE row (`events_room_state_idx`; run it off-peak, inside a rolled-back transaction). The latest member event is chosen like the server does: newest `origin_server_ts`, a tie most restrictive first, then `event_id` descending; the `membership` is read from both JSONB forms of `content` (an object, or a string that holds the JSON text). A repeated `POST /rooms/{roomId}/ban` of the user repairs a row (it removes the member and rejects a pending invitation, and writes no new event).

```sql
SELECT m.room_id, m.user_id, m.joined_at, latest.origin_server_ts AS banned_at
FROM room_members m
JOIN LATERAL (
  SELECT me.origin_server_ts, me.membership
  FROM (
    SELECT e.event_id, e.origin_server_ts,
           CASE jsonb_typeof(e.content)
             WHEN 'object' THEN e.content ->> 'membership'
             WHEN 'string' THEN CASE WHEN pg_input_is_valid(e.content #>> '{}', 'jsonb')
                                     THEN ((e.content #>> '{}')::jsonb) ->> 'membership' END
           END AS membership
    FROM events e
    WHERE e.room_id = m.room_id AND e.event_type = 'm.room.member' AND e.state_key = m.user_id
  ) me
  ORDER BY me.origin_server_ts DESC,
           CASE me.membership WHEN 'ban' THEN 0 WHEN 'leave' THEN 1 WHEN 'invite' THEN 2
                              WHEN 'knock' THEN 3 WHEN 'join' THEN 4 ELSE 1 END ASC,
           me.event_id DESC
  LIMIT 1
) latest ON true
WHERE m.left_at IS NULL
  AND latest.membership = 'ban'
ORDER BY m.room_id, m.user_id;
```

**History visibility (story history-visibility-enforcement, follow-up `es`).** Behaviour change, no migration, no new
setting. *What members see now.* In a room whose history visibility is `invited` ("Members only (since they were
invited)") or `joined` ("Members only (since they joined)"), a member who is invited or joins later no longer sees the
events from before his invitation / join: not in the timeline (`/messages`, `/sync`, `/initialSync`), not in search,
not through a permalink (`/event`), not through a thread or a relation, and the `prev_content` of a predecessor he may
not see is omitted; a re-joiner does not see the events of the time he was away. Nothing changes for `shared` rooms:
the default of every preset and of every room without the setting. The current state (name, topic, members, bans)
stays visible to every joined member. *No backfill, no deletion:* events stay stored and are served to the members
who may see them; changing the setting affects the events after the change only. *Failure mode.* A failing read
answers `500` (the incremental `/sync`: `503 M_UNAVAILABLE`, the client retries) with one ERROR line naming the room id
and the error class. *Operator queries* (read-only, one statement each, no parameters; run them off-peak with a
read-only role; both were checked in a rolled-back transaction with fixture rows; PostgreSQL 16 or later for
`pg_input_is_valid`). *Limits (security cycle 1).* A room holds at most 256 history-visibility state events (the write
above it is `429 M_LIMIT_EXCEEDED`, except a strictly more restrictive change: the cap never blocks tightening); a PUT of `m.room.history_visibility`, `m.room.guest_access` or `m.room.join_rules`
costs a `moderation` token; their values are validated on write (`400 M_BAD_JSON`); the request reads run under a 2 s
statement timeout (a timeout is a `500`, the `/sync` reads are not under it). Existing rooms above 256 events keep their
events (no deletion) and accept only tightening changes. **Q-hv1** lists the rooms whose CURRENT setting is `invited` or `joined`
(the rooms where later joiners now see less); a room that was restricted earlier and changed back to `shared` keeps a
hidden segment for the events of the restricted period and is NOT listed:

```sql
-- Q-hv1: the rooms whose current history visibility is invited or joined
SELECT room_id
FROM (
  SELECT DISTINCT ON (room_id) room_id,
         CASE jsonb_typeof(content)
           WHEN 'object' THEN content->>'history_visibility'
           WHEN 'string' THEN CASE WHEN pg_input_is_valid(content #>> '{}', 'jsonb')
                                   THEN ((content #>> '{}')::jsonb)->>'history_visibility' END
         END AS setting
  FROM events
  WHERE event_type = 'm.room.history_visibility' AND state_key = ''
  ORDER BY room_id, origin_server_ts DESC, event_id DESC
) current_setting
WHERE setting IN ('invited', 'joined')
ORDER BY room_id
```

**Q-hv2** lists the inputs of the per-read cost (follow-up `gk`: every filtered read computes the segments from the
room's history-visibility events and the reader's member events): the 20 rooms with the most history-visibility
events and the 20 (room, user) pairs with the most member events, with their counts:

```sql
-- Q-hv2: the 20 rooms with the most hv events, the 20 (room, user) pairs with the most member events
(SELECT 'history_visibility_events' AS kind, room_id, NULL::text AS user_id, count(*) AS events
 FROM events
 WHERE event_type = 'm.room.history_visibility' AND state_key = ''
 GROUP BY room_id
 ORDER BY count(*) DESC, room_id
 LIMIT 20)
UNION ALL
(SELECT 'member_events', room_id, state_key, count(*)
 FROM events
 WHERE event_type = 'm.room.member' AND state_key IS NOT NULL
 GROUP BY room_id, state_key
 ORDER BY count(*) DESC, room_id, state_key
 LIMIT 20)
```

### Preconditions

Status values are derived from `docs/stories/oauth-broker/follow-ups.md` and the Dev Agent Records of the phase-2 stories; they describe the state after phase 2 (2026-10-13). **Nothing here says OAuth is activated: `oauth_enabled` stays `false` until an operator flips it.** Vocabulary: **closed (story X)** = implemented and tested in the server; **closed in deploy templates** = done in `deploy/` (verify after deploy); **MANUAL VERIFICATION REQUIRED** = fails closed in code, but the behaviour of a real IdP, client, browser, load balancer or operator procedure must be verified and recorded (details in "Manual verification before activation" below); **open** / **deferred** = not done, with the reason.

**Epic SEC gate 3 (2026-10-13): dormant merge PASS; activation blocked** on G3-2 (positive client-IP test, docs / operator, gating) and the manual verification groups A-F. G3-1 (revoke lock bounds) is closed by the bugfix `revoke-lock-bounds`; **G3-3 (legacy SSO `redirectUrl` trust) is closed in the server by the story `legacy-sso-redirect-confirmation`** (confirmation page for unlisted https targets, see "Legacy SSO confirmation page"; manual verification group F).

| Item | What | Current status | Owner |
|---|---|---|---|
| 1 | Trusted-proxy client-IP resolution (HARD GATE): `NEBU_TRUSTED_PROXY_CIDRS` (story oauth-trusted-proxy-client-ip); `NEBU_TRUSTED_PROXY` is not read | closed in the server (story oauth-trusted-proxy-client-ip) and wired into the reference templates (story P5); MANUAL VERIFICATION REQUIRED: operator must configure and verify the CIDR list, the LB append semantics and the negative spoof test BEFORE flipping (group A below; see "Client IP behind a reverse proxy") | server / operator |
| G3-2 | Client-IP POSITIVE test (epic SEC gate 3): two clients on different networks must show DISTINCT real `last_seen_ip` values through the real public path | **MANUAL VERIFICATION REQUIRED, GATING (docs / operator)**: a correct CIDR list plus a load balancer that does not append the client address passes every spoof test and still makes all per-IP buckets and per-source caps global (login denial of service by one anonymous source, consent cap 20, authz / account caps 300). `tofu alb` with an empty `lb_real_ip_cidrs` = do NOT flip `oauth_enabled` (group A, activation step 0). The legacy SSO confirmation page is NOT affected any more (story sso-confirm-bucket-order, follow-up `cv`: it counts requests by the binding cookie, a flood without a live binding cannot lock it for the users who have one; ADR-033 L9) | operator |
| G3-3 | Legacy SSO `redirectUrl` trust: `GET /_matrix/client/v3/login/sso/redirect?redirectUrl=<any https URL>` used to end in a 302 to that host with a `loginToken` that `POST /login` exchanges for a full session (pre-existing, independent of `oauth_enabled`; the E-2 closure covered the OAuth path only) | **closed (story legacy-sso-redirect-confirmation; MANUAL VERIFICATION REQUIRED, group F)**: a stricter `redirectUrl` parser (userinfo, backslash, control characters, numeric host lookalikes are `400`) and a CONFIRMATION PAGE after the IdP login for every https target that is not listed (own `https://<server_name>`, the `oauth_issuer_url` origin, the registered redirect URIs of approved OAuth clients, the operator list `sso_redirect_allowed_origins`); only Continue mints the `loginToken`. **Behaviour change for legacy clients:** see "Legacy SSO confirmation page" and the release note. Migration 000048 | server (done); operator: list the origins of your web clients, verify group F |
| 2 | Bulk removal of pending registrations (by host/registrable domain, by age; audited) | closed (story oauth-dcr-abuse-hardening); browser pass is MANUAL (group D) | server |
| 3 | Public-suffix check (built-in list; suffix hosts refused; warning badge) | closed (story oauth-dcr-abuse-hardening) in the server; the list is hand-picked (follow-up ar), a miss means coarser grouping, never a weaker check | server |
| 4 | Per-host pending cap keyed on (registrable domain, client source) | closed (story oauth-dcr-abuse-hardening); effective only with item 1 configured; MANUAL: 21st registration from one source answers `503`, another source `201` (group A) | server |
| h | Per-source caps on live `oauth_authz_requests` (300 per source, /64) and `oauth_account_login_requests` | closed (story oauth-dcr-abuse-hardening); effective only with item 1 configured; MANUAL: 300 abandoned authorizes from one network do not block a real login (group A) | server |
| i | Interactive login / `auth_time` freshness at the authorize callback (or a consent screen) | closed (story oauth-authorize-freshness): consent on every authorization; MANUAL: consent flow in the real clients (group C) | server |
| l | Detect a missing IdP refresh token at the IdP callback (`per_refresh`) | closed (story oauth-authorize-freshness): `server_error` before provisioning + one WARNING; MANUAL: an IdP client that issues no refresh token (group B) | server |
| m | Reverse-proxy routes (see below), also `/account*`; templates also set `NEBU_TRUSTED_PROXY_CIDRS` and log without query strings | closed in deploy templates (story P5); MANUAL VERIFICATION REQUIRED after deploy: routes, negative XFF test (group A). Operators with their own proxy must configure all of it themselves | operator / deploy |
| k | Strip query strings of `/oauth2/authorize`, the SSO callback and `/account` in reverse-proxy access logs | closed in deploy templates (story P5: `log_format nebu_noquery`, `error_log crit`); residuals: certbot's port-80 block and the default `access.log` of `acme`, nginx `error_log` diagnostics at `crit` (follow-up ap8). Own proxies: operator | operator / deploy |
| n | False logout when two refreshes of one RT overlap and the IdP rotates refresh tokens | closed (story oauth-authorize-freshness): per-device IdP refresh lease; MANUAL: scripted parallel refresh against Dex and an IdP with reuse detection (group B); accepted residual: no fencing token (follow-up az) | server |
| j | Per-flow binding cookies carry the `__Host-` prefix on https | closed (story oauth-hardening-hygiene, HY9); MANUAL: cookie attributes behind the real proxy, which must send `X-Forwarded-Proto: https` (group A) | server / operator |
| r | Legacy `POST /logout` per device: it ends only the presented credential's device (rows, device, keys) with the locked teardown; legacy `/refresh` takes the devices lock (x) | closed by bugfix legacy-logout-per-device; MANUAL: logout in Element Web / FluffyChat with a second client alive (group C) | server |
| x | Legacy `rotate_tokens/1` took no `devices` lock (a refresh could survive a device deletion) | closed by bugfix legacy-logout-per-device (LL9) | server |
| s | `device_lists.changed` on every device deletion (legacy and OAuth `/logout`, `/logout/all`, `/oauth2/revoke`, `DELETE /devices`, account page, admin, take-over, client revocation): peers do not learn that a device was deleted | **open, deferred and re-scoped (decision 2026-10-13)**: NOT implemented in this phase and no longer an activation gate, because Nebu refuses encrypted rooms (ADR-011), so no peer encrypts to a device, and the design (a new change-log table, a `/sync` token change) is risky. The gate is now: before encrypted rooms are allowed (ADR-011 lifted) and before any release that claims E2EE. Story `device-lists-changed-on-deletion` stays in the backlog (reserved ids bv, bw, bm-bo). Acknowledge it in the release notes | server (backlog) |
| w | OAuth sessions could not delete devices | closed by story 6 (account page) | - |
| y | Login no longer needs `auth_time` (consent on every authorization); without it `/account` destructive actions are unavailable (fail closed); release note aw (planned as aq before oauth-dcr-abuse-hardening took that id); Dex reportedly ignores `max_age` and omits `auth_time` | closed (story oauth-authorize-freshness); MANUAL: record what Dex and the production IdP really emit (group B) | server (done) |
| i / y (server-owned) | Interactive login and freshness must be enforced SERVER-side, fail closed (absent `auth_time` = not fresh) or a consent screen: not an IdP prerequisite (epic SEC gate E-2) | closed (story oauth-authorize-freshness): consent on every authorization (FR1) and a fail-closed account page (FR14); also E-2 | server |
| E-2 | Epic SEC gate E-2 "(i)/(y) sharpened" (device takeover chain through a silent IdP SSO) | closed (story oauth-authorize-freshness, FR1-FR3 / FR11 / FR14), same evidence as i / y | server |
| ac | `GET /_matrix/client/v1/room_summary/{roomIdOrAlias}` is CORE in Matrix v1.15 and absent (GATE before `oauth_enabled` and before a release claiming v1.15; (af) `M_UNRECOGNIZED` for unrouted paths ships with it) | closed (story oauth-room-summary-unrecognized, with af): local-only summary, per-user rate limit, 404 for every hidden room; MANUAL: room preview in Element Web / FluffyChat (group C) | server |
| af | Unrouted endpoints and unsupported methods answer `M_UNRECOGNIZED` (404 / 405), unauthenticated | closed (story oauth-room-summary-unrecognized, RU9-RU16; `GET /rooms/{id}/state[/...]` keeps `404 M_NOT_FOUND`, follow-up bf); MANUAL: no new client errors (group C) | server |
| ag | Same-origin approval of a cross-signing reset (`/account` shares the origin with Element Web) AND of client registrations (`/admin`, epic SEC gate E-3): dedicated account/admin origin, or navigate/Sec-Fetch checks + fresh admin re-authentication + a documented accepted risk | server side closed by oauth-client-revocation (strict fetch metadata on approve / revoke / reset approval, fresh admin re-authentication, no framing of `/admin/oauth/*`); operator: acknowledge SO7 (below) or move Element Web to its own origin (SO8 decision); MANUAL: real browsers (group D) | operator / server |
| ag (E-3) | `/admin` registration approval from a same-origin script (epic SEC gate E-3, extends ag) | closed in the server by oauth-client-revocation (SO1-SO6) together with ag; the dedicated admin origin is not possible yet (follow-up ba) and the shared origin is the accepted risk SO7 | operator / server |
| aj | Withdraw an approved client (`revoked` status, cascade teardown of its sessions/codes/devices, admin list of approved clients + Revoke with audit; epic SEC gate E-1) | closed by oauth-client-revocation (server): see "Revoking a client"; MANUAL: revoke rehearsal with a live session, `bin/nebu rpc` in the reference containers (group E) | server |
| G3-1 | A long client revocation holds the torn-down `devices` rows and bypassed the 2 s bound for the `per_refresh` lease claim and the `/sync` last-seen update (epic SEC gate 3, MEDIUM) | closed in the server by bugfix revoke-lock-bounds (lease claim / release and the request-path teardowns under a 300 ms `lock_timeout` -> `503` + `Retry-After: 5`; last-seen and pending-grace updates skip locked rows; no role-level `lock_timeout`); MANUAL: load rehearsal with a client holding thousands of devices (revoke while refreshes, `/sync` and logouts run: 503s on refresh, the node stays responsive, pool pressure proportional to the active devices); a very large revoke still holds its rows = follow-up bb | server |
| ak(1) | An approved cross-signing replacement with an explicit `null` key value reopens the UIA-free first-upload branch: reject/drop nil and non-map values before digest and merge (story-6 delta review) | closed (story oauth-authorize-freshness); ak(2)/(3) too, ak(4) open (non-gating) | server |
| ae | Health checks and runbooks probed `/_matrix/client/v3/versions`, which is not routed | closed in deploy templates / `deploy/` (story P5): Helm readiness, the AWS target group, the UpCloud / Stackit LB probes and the RUNBOOKs use `GET /_matrix/client/versions`, Helm liveness uses `/health`; a probe of the `v3` path answers `404 M_UNRECOGNIZED`. Own probes: operator | operator / deploy |
| aa | Per-source caps for account login requests and sessions | closed for login requests (AH11, story oauth-dcr-abuse-hardening, effective only with item 1); sessions need none (authenticated, 20 per user) | server |
| am | Unauthenticated DB load: per-node cache of the switch state, rate limits on `GET /login` and the live openid-configuration | closed (story oauth-hardening-hygiene, HY1-HY3); the spec-unlimited discovery paths rely on the cache only (follow-up br); MANUAL: cache TTL on two real nodes (group A) | server |
| an | Hygiene: compile-guarded config seams, stale doc lines, revoke runbook | closed (story oauth-hardening-hygiene, HY5; the revoke runbook by oauth-client-revocation) | server |
| p | Signing-key cache owned by a supervised process; runbook for an undecryptable active key | closed (story oauth-hardening-hygiene, HY4 + HY13); the SecretBox part is deferred, see (al) | server |
| story-3 (b) | Signing-key rotation tooling and runbook | closed (story oauth-hardening-hygiene, HY11-HY13); MANUAL: rotation rehearsal with real client sessions (group E) | server / operator |
| al | One internal secret protects everything encrypted at rest (no key id, no AAD); rotating it = mass logout of `per_refresh` sessions + id_token outage | deferred (P8): design in ADR-033 HY17, two-release rollout; release note now | server (follow-up) |
| o | One `matrix_sessions` row per rotation kept until `session_expires_at + 7 d` | deferred (P8): a row cap would shorten the T11 reuse-detection window; alternative design (bs) | server (follow-up) |
| t | Optional IdP-side revocation of the IdP refresh token | deferred (P8): the ciphertext must outlive every teardown path, new outbound IdP code, only verifiable against a real IdP | server (follow-up) |
| q | Switching `idp_revalidation` `off` to `per_refresh` revokes sessions without an IdP RT at their next refresh; IdP refresh load per client | open, release note (non-gating) | operator |
| u | Raw IdP JWT path (unbound raw JWTs) | open: non-gating, when legacy is deprecated | server (follow-up) |
| v | Admin device list shows no owning API / OAuth client | open: non-gating, epic-end review | server (follow-up) |
| z | The account page cannot deactivate the account nor edit the profile | open: product decision, deactivation stays with the administrator | product |
| ab | Audit rows for cross-signing reset approvals and account-page device deletions | open: compliance decision (INFO log lines only today) | compliance |
| ai | Switch-off suspends OAuth, it does not revoke it | open, non-gating (documented runbook): `Nebu.Release.revoke_all_oauth_sessions/0` after the switch-off; automatic revocation and a UI are follow-ups (bc); MANUAL: rollback rehearsal (group E) | operator |

Non-gating items to know about: (al) one internal secret protects everything encrypted at rest (rotation = mass OAuth logout + id_token outage: release note; the id_token key itself is re-keyed with `replace_oauth_signing_key(:emergency)`; SecretBox v2 design in ADR-033 HY17: deferred (P8)), (3) public-suffix check, (q) `idp_revalidation` switch note, (ai) switch-off suspends instead of revoking, (o) rotated session rows (a row cap would shorten reuse detection: deferred (P8), follow-up bs), (t) IdP-side revocation (deferred (P8)), (u) raw-JWT path, (v) admin device list owner, (z) no deactivation / profile editing on the account page, (aa) per-source account caps, (ab) audit rows for resets and device deletions, story-3 (f) legacy device reuse; the new (ad) pre-existing endpoint gaps; (ae) health checks probing `/_matrix/client/v3/versions` is fixed in `deploy/` by story P5 (the route is `/_matrix/client/versions`; Helm liveness uses `/health`, readiness / AWS target group / LB probes use `/_matrix/client/versions`). New non-gating items (see follow-ups): `lb_real_ip_cidrs` has no safe default and the LB assumptions (append semantics, source CIDR) are unverified, and the acme / certbot residual log formats.

The table above is authoritative where it differs from the paragraph before it. Other non-gating follow-ups (none blocks the flip; see `follow-ups.md`): the /48 IPv6 tier and the `SourceKey` hash key (ao, at, aq), the suffix list (ar), configurable per-source caps (as), remembered consent (av), refresh-lease fencing (az), configurable admin hostname (ba), batched revoke of very large clients (bb), revoke-all UI (bc), per-user txn-id dedup (bd), `GET /rooms/{id}/state` (bf) and the room-summary side findings (bg-bl), scheduled signing-key rotation (bq), the discovery rate limits (br), rotated-row growth (bs), config-cache eventual consistency (bt), the Helm value for `NEBU_TRUSTED_PROXY_CIDRS` (bu), PROXY protocol for TCP-mode load balancers (ap3), `X-Forwarded-Proto` gating (ap2), the bucket fallback behind a trusted proxy (ap4) and the personal-data note for `last_seen_ip` / `created_from_ip` (ap5). **Device-list changes on device deletion ((s)) are deliberately not implemented in this phase**: Nebu refuses encrypted rooms (ADR-011), so no peer encrypts to a device; the gate is re-scoped to "before encrypted rooms are allowed and before any release that claims E2EE" (row s).

### Reverse proxy

Route `/oauth2/`, `/account`, `/account/` and `/.well-known/openid-configuration` (and keep `/_matrix/`, `/.well-known/matrix/`) to the server whenever Element Web is served on the same host. Strip the query strings of `/oauth2/authorize`, the SSO callback and `/account` from access logs (k): they carry state, codes and identifiers. Story P5 wires this into the reference templates (`deploy/tofu/examples/{stackit,upcloud}/cloud-init.tftpl`) for the nginx proxy (`tls_mode` `acme`, `alb`, UpCloud `dynamic`; `none` has no proxy):

- Routes (when `enable_element_web = true`; otherwise `location /` sends everything to the server): `/oauth2/`, `= /account`, `/account/` and `= /.well-known/openid-configuration` (plus `/.well-known/matrix/`) go to the server in the compose `alb` proxy and in the host nginx of `acme`, in addition to `/_matrix/`, `/admin/`, `/api/v1/`. `/account` is an exact match and `/account/` a prefix, so `/accountx` is NOT captured and stays with Element Web.
- Logging: both nginx instances use `log_format nebu_noquery` (`$uri` only, never `$request`, `$request_uri` or `$http_referer`), so the query strings of `/oauth2/authorize` (state, `code_challenge`, `login_hint`), the SSO callback (code, state) and `/account` never reach the access log (k). `error_log` is set to `crit` (`alb`: `/dev/stderr`, `acme`: `/var/log/nginx/nebu-error.log`) because nginx prints the full request line, query string and referrer for upstream errors (502/504) at level `error`; the residual cost is that upstream failures are no longer diagnosable from the proxy's error log (use the access log status / `rt=` and the server logs). Residuals: in `acme`, certbot's port-80 redirect block and the default `/var/log/nginx/access.log` keep nginx's combined format (query string included; they only see plain-http requests that get redirected). cloud-init renders these files at first boot: an existing VM keeps its old nginx config and log format until the rendered files are applied (VM recreate, or by hand followed by a `nebu.service` restart).
- `X-Forwarded-For` is OVERWRITTEN with `$remote_addr` in every `proxy_pass` location (never `$proxy_add_x_forwarded_for`), so Nebu always receives exactly one element, written by nginx.
- Listeners of the `alb` proxy container (UpCloud `alb` / `dynamic`, Stackit `alb`): `:8081` carries the TLS-terminated LB traffic with full routing and is the ONLY listener that can carry the `realip` directives; `:80` carries the plain-HTTP LB frontend / listener plus the health probe (`GET /_matrix/client/versions`), never trusts any `X-Forwarded-For` and answers everything else with `308` to `https://<server_name>`. UpCloud: the `https-443` frontend (HTTP mode, rule `set_forwarded_headers`) targets VM port `8081`; the `http-80` frontend is HTTP mode with a `http_redirect` (301) rule (for `dynamic` the ACME HTTP-01 path is excluded; revert `http-80` to TCP for `dynamic` if the certificate issuance fails behind HTTP mode); `acme` and `none` stay TCP. Stackit `alb`: target pools `matrix-api` (VM `8081`, listener `https-443`) and `matrix-api-http` (VM `80`, listener `http-80`; the provider has no redirect action, so the redirect is the nginx `:80` listener); security group rule `8081` from `network_cidr`. Health checks probe `/_matrix/client/versions` (follow-up (ae)).

**Element Web on its own origin (story oauth-client-revocation, SO8; recommended).** Element Web, `/account` and `/admin` share one origin in the reference deployments, so a script running in Element Web (XSS) is same-origin with the pages that approve a client or a cross-signing reset. The code hardens those actions (strict fetch metadata, fresh admin sign-in, no framing, see "Accepted risks" SO7) but cannot remove the class: serve Element Web on its own hostname and keep only Nebu's own paths on the Nebu host. Example (the Nebu host `chat.example.com` keeps `/_matrix`, `/.well-known`, `/oauth2`, `/account`, `/admin`; the static client moves):

```nginx
# element.example.com: ONLY the static Element Web files; no /account, /admin, /oauth2, no cookies of the Nebu host
server {
    listen 443 ssl;
    server_name element.example.com;
    root /usr/share/nginx/element;        # the Element Web build (config.json with "default_server_config" pointing at chat.example.com)
    location / { try_files $uri /index.html; }
    add_header Content-Security-Policy "frame-ancestors 'self'" always;
}
```

Register `https://element.example.com/` in the Element Web `config.json` (`m.homeserver.base_url` = `https://chat.example.com`) and add the Element origin to nothing else: the Nebu host needs no CORS change for it beyond what the Matrix API already allows. A dedicated ADMIN hostname is not possible yet (`/admin/callback` is derived from `server_name`: follow-up ba). Until Element Web moves, the shared origin is an accepted risk (SO7 below).

### Topology at a glance (phase 2, reference templates)

```
Internet ──► load balancer (UpCloud / Stackit; TLS, HTTP mode, XFF behaviour UNVERIFIED) ──► nginx proxy container (compose `alb`, pinned `.10`)
                                                                                           :8081 TLS-terminated traffic (the only realip listener)
                                                                                           :80   health probe + 308 redirect (never trusts XFF)
            nginx routes:  /_matrix/  /.well-known/matrix/  /admin/  /api/v1/  /oauth2/  = /account  /account/  = /.well-known/openid-configuration  ──► server:4000
                           everything else (/) ──► Element Web (127.0.0.1:7070)        access_log without query strings, error_log crit,
                           X-Forwarded-For OVERWRITTEN with $remote_addr                 NEBU_TRUSTED_PROXY_CIDRS = <pinned proxy>/32
acme (host nginx, no LB XFF): host nginx ──► 127.0.0.1:8008 / 127.0.0.1:8080 (published on loopback only); trusted = compose gateway /32
none: public :8008, NO trusted proxy (shared buckets)
```

Loopback-bound server ports, the pinned compose subnet (`compose_subnet`) and the narrow `lb_real_ip_cidrs` are the template-side half of gate item 1; the operator-side half is the negative spoof test ("Manual verification before activation", group A).

### Client IP behind a reverse proxy (`NEBU_TRUSTED_PROXY_CIDRS`)

Story `oauth-trusted-proxy-client-ip` (gate item 1, ADR-033 section "Trusted-proxy client IP"). Every per-IP decision (login / refresh / sync / write rate limits, the OAuth buckets, the dynamic-client-registration abuse control, `oauth_clients.created_from_ip`, `devices.last_seen_ip`) uses ONE resolved client address. Without configuration that is the direct TCP peer, so behind nginx every client shares one bucket. To get the real client, list YOUR proxies:

```
NEBU_TRUSTED_PROXY_CIDRS=172.18.0.0/16,192.0.2.10,2001:db8::/32
```

- Format: IPv4 / IPv6 address literals with an optional `/prefix`, separated by commas and/or whitespace (`10.0.0.0/8`, `172.18.0.0/16`, `192.0.2.10` = `/32`, `::1` = `/128`). Default: none (empty or unset = the direct peer is the client, no log line). Parsing is fail-closed: an invalid entry (`10.1`, `010.0.0.1`, `10.0.0.1/8` with host bits set, `*`, `all`, `true`, zones, ports, brackets, IPv4-mapped IPv6 entries) is ignored and reported in ONE boot warning; more than 64 entries or 4096 bytes ignore the whole variable. A set of valid CIDRs logs one info line with the count. The legacy `NEBU_TRUSTED_PROXY` is not read.
- Algorithm: the `X-Forwarded-For` header is honoured only when the direct peer is inside the list; the header lines are joined, walked from the right, trusted hops are skipped and the first (rightmost) untrusted element is the client. Anything malformed, empty, over 2048 bytes, more than 20 hops, or fully trusted falls back to the direct peer (never to the leftmost element).
- Proxy requirement: every trusted hop must APPEND to the header (nginx: `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`) or, on the outermost proxy that faces the internet, OVERWRITE it (`proxy_set_header X-Forwarded-For $remote_addr;`). A proxy that passes a client-written header through unchanged and is itself the first hop must overwrite.
- List only the addresses of YOUR proxies, never client networks: trust the pinned address of the nginx container as a `/32` (and `/128`), NOT the whole compose subnet (the subnet also contains the Docker gateway and every other container). Docker picks the compose subnet at random unless it is pinned; pin it and the nginx address, and confirm with `docker network inspect`. A load balancer's network is listed only if the LB was verified to APPEND the client address to (or overwrite with it) `X-Forwarded-For`; an LB that merely forwards the header lets a client write the address Nebu uses, so in that case do not list the LB and accept the LB-shared bucket.
- Bind the published host ports (`8008`, `8080`) to `127.0.0.1` BEFORE trusting the Docker gateway, and keep them unreachable from untrusted networks. Which source address Nebu sees on a published port depends on how Docker forwards: with the default iptables DNAT an external IPv4 client keeps its own source address, but connections from the host loopback, IPv6 clients reaching an IPv4-only bridge (userland proxy) and rootless / Docker Desktop installations arrive from the bridge gateway. A trusted gateway therefore lets any client who can reach the port choose its bucket. IPv6 needs the same care: list IPv6 proxy addresses as `/128`, and check that the proxy does not forward an IPv6 client to Nebu without appending its address.
- `0.0.0.0/0` and `::/0` are accepted when written literally but log a loud boot warning: every peer is trusted, so any client that reaches Nebu directly can choose its rate-limit bucket. Use them only when a network boundary guarantees that only your proxies can connect.
- The RFC 7239 `Forwarded` header and `X-Real-IP` are ignored entirely (also when `X-Forwarded-For` is absent); a proxy that can only emit `Forwarded` must be configured to emit `X-Forwarded-For`. `X-Forwarded-Proto` handling (the `Secure` cookie flag) is unchanged and not gated by this list.
- Verification recipe: **POSITIVE test (GATING, as important as the negative one; G3-2):** log in from two clients on different networks THROUGH THE REAL PUBLIC PATH (the load balancer and the proxy, not a direct port) and compare `last_seen_ip` (`/admin` users page or `GET /_matrix/client/v3/devices`): the two values must be DISTINCT, real client addresses and must not show a proxy or load-balancer address. If they are equal (or both show the LB / proxy address), every client collapses into ONE bucket: do NOT flip `oauth_enabled`. A passing negative test does not prove this: a correct trusted-CIDR list with a load balancer that does not append the client address passes every spoof test and still makes all buckets global; hammer `POST /_matrix/client/v3/login` from one client and confirm the other still gets answers (independent `429`). NEGATIVE test (detects a spoofable setup): send a login with the forged header `X-Forwarded-For: 203.0.113.99` through the public endpoint over IPv4 AND over IPv6 (`https://`, and on the `alb` templates also plain `http://` port 80), and directly to `:8008` / `:8080` if they are reachable from where you test; `last_seen_ip` must never show `203.0.113.99`. If it does, the LB or a listed network lets clients write the header: remove it from `NEBU_TRUSTED_PROXY_CIDRS`. An empty or invalid list never allows spoofing (it only leaves today's shared buckets); a too-broad list does. **The shared-bucket outcome is safe against spoofing but NOT safe for availability:** with all clients in one bucket, one anonymous source can exhaust the per-IP buckets (for example 600 `GET /oauth2/authorize` per hour) and every per-source cap (consent 20 per source, authorize and account login requests 300, pending registrations 100) becomes server-wide, so that source can lock every user out of OAuth login. **`tls_mode = alb` (UpCloud `alb` / `dynamic`, Stackit `alb`) with an empty `lb_real_ip_cidrs` = do NOT flip `oauth_enabled`** unless the positive test shows distinct client addresses (for example because the proxy sees the client directly).
- Misconfiguration warnings (story client-ip-misconfiguration-warnings). Nebu and the reference templates warn where a collapsed or unresolved client address is reliably visible; none of them blocks anything, and the ABSENCE of a warning proves nothing (a small deployment, a collapse to three or more LB addresses, or a correct-looking list behind an LB that does not append the client address all stay silent): it does NOT replace the positive test above. (1) Server log, at most once per 10 minutes per node: `client IP: a request carried X-Forwarded-For but its direct peer is not in NEBU_TRUSTED_PROXY_CIDRS, so the header was ignored ...` proves that SOMETHING in front of Nebu writes the header and that its peer address is not listed (an empty `NEBU_TRUSTED_PROXY_CIDRS` behind a proxy, a pinned address that does not match the real peer: check `docker network inspect` and the pinned addresses (ap7), a changed compose subnet) OR that a client wrote the header itself; it does not say which. React: list ONLY an exact proxy address you verified, or ignore it on a direct deployment where clients send the header themselves; NEVER widen `NEBU_TRUSTED_PROXY_CIDRS` to silence it (re-opens spoofing, worse than the availability problem), and note that your own negative test (forged header to a direct port) fires it too. W1 cannot fire for the `alb` collapse with an empty `lb_real_ip_cidrs` (nginx is a trusted peer there): only W2 (after 24 h of traffic from at least 5 users) and the `tofu plan` check see that case. (2) Server log, every 6 hours (Oban cron `37 */6 * * *`): `client IP: all <n> devices of <u> users active in the last 24 h were seen from at most <a> client address(es) ... oauth_offered=<true|false>` fires when at least 10 active devices of at least 5 users share at most 2 addresses (`devices.last_seen_ip`, counts only, never an address): the signature of a load balancer or proxy that does not pass the client address on. React: run the positive test, set `lb_real_ip_cidrs` after the negative test; a deployment whose users really all share one network address (single NAT) can ignore it (it cannot be silenced, follow-up ch). On a very large `devices` table the read can hit its 5 s statement timeout on every run; the failure is then logged as `client IP: device address check failed: postgres query_canceled` (counts only) and the check is blind. (3) `tofu plan` / `tofu apply` in the reference templates (`client_ip_check.tf`, the `check` block `client_ip_resolution`, a warning only): `tls_mode` `alb` / `dynamic` (Stackit: `alb`) with an empty `lb_real_ip_cidrs`, and the UpCloud TCP-mode frontends `none` / `acme`; a non-empty `lb_real_ip_cidrs` silences the first assert and does NOT prove correctness. Not covered: Stackit `acme` / `none` (follow-up ci). Nothing in the server can tell a collapsed address from a legitimate one, so activation is not blocked in code (it is an SQL write, step 1 below).
- Rate-limit keys: IPv4 clients are keyed per address, native IPv6 clients per /64 network (one routed /64 must not mint unlimited buckets); `devices.last_seen_ip` and `oauth_clients.created_from_ip` keep the exact address. Idle buckets are evicted per node (every 10 minutes, idle > 1 hour).
- Privacy and retention: with this variable set, `devices.last_seen_ip` and `oauth_clients.created_from_ip` hold REAL client IP addresses (personal data) instead of the proxy address. Treat them accordingly (privacy notice, retention; deleting a device or a client row removes the value).
- Reference templates (story P5, gate m; verify after deploy). `NEBU_TRUSTED_PROXY_CIDRS` is set by `deploy/tofu/examples/{upcloud,stackit}/cloud-init.tftpl`, derived by OpenTofu from a pinned compose network (variable `compose_subnet`, default `172.30.0.0/24`, IPv4 prefix `/16` to `/27`, must not overlap `network_cidr` (precondition); Docker's dynamic pool `ip_range` is the upper half, gateway `.1`, nginx proxy container `.10`):
  - `tls_mode = "alb"` (and UpCloud `dynamic`): `<.10>/32` (the pinned proxy container); published `8008` / `8080` are bound to `127.0.0.1`.
  - `tls_mode = "acme"`: `<.1>/32` (the compose gateway: Docker delivers host nginx's loopback connection from it); valid ONLY because `8008` / `8080` are published on `127.0.0.1:8008` / `127.0.0.1:8080`.
  - `tls_mode = "none"`: public `8008` (the LB target), NO trusted proxy.
  - Variable `trusted_proxy_cidrs` (default empty) REPLACES the derived value in every mode; validated as comma-separated CIDRs without whitespace, IPv4 prefix `/16` or longer, IPv6 `/48` or longer (`0.0.0.0/0`, `::/0` refused), and forbidden for `tls_mode = "none"` (precondition).
  - Optional variable `lb_real_ip_cidrs` (list, default empty; UpCloud `alb` / `dynamic`, Stackit `alb` only; output `lb_private_addresses` on UpCloud): the exact `/32` LB hop address(es), validated as narrow CIDRs (IPv4 `/16`+, IPv6 `/48`+) and as lying inside `network_cidr`. When set, the `:8081` listener (only that one, never `:80`) renders `set_real_ip_from` per entry, `real_ip_header X-Forwarded-For` and `real_ip_recursive on`, so nginx resolves the client as the rightmost address that is not a listed hop and forwards exactly that one address to Nebu. The LB CIDR is trusted by nginx, never by Nebu. Set it ONLY after verifying that the LB APPENDS the client address to `X-Forwarded-For` (negative test above, over `https://` AND `http://`, IPv4 AND IPv6); empty (default) = all clients share the LB's bucket (fail-safe for spoofing, NOT for availability: one anonymous source can then exhaust every per-IP bucket and per-source cap for everybody; see the positive test below, and do not flip `oauth_enabled` in this state). There is no safe default: the LB source address and the append semantics are not documented by the providers.
  - TCP-mode load balancers (UpCloud `acme` / `none`, Stackit NLB) cannot carry `X-Forwarded-For`: the client address is lost without PROXY protocol (follow-up ap3), not supported.
  - Existing VMs need a `nebu.service` restart for the pinned subnet to take effect, and a `compose_subnet` that does not overlap `network_cidr`.

### Issuer

`oauth_issuer_url` is the public https origin clients use: empty path, no query, no fragment, no userinfo, the same host as the IdP callback (the Admin UI form of "The Admin UI switch" validates with the same function). A misconfigured issuer silently keeps everything off (fail closed); verify with `curl <issuer>/_matrix/client/v1/auth_metadata` (200) and `curl <issuer>/_matrix/client/versions` (lists v1.15).

### IdP

`matrix_oidc_refresh_mode = offline` when `oauth_idp_revalidation = per_refresh` (the stored IdP refresh token is redeemed at every refresh). An IdP that emits `auth_time` enables `/account` device deletion and key-reset approval for OAuth users (without it those actions are unavailable, fail closed; the consent page then shows a notice); `prompt=create` is only sent when the IdP advertises it.

### Consent and freshness verification (story oauth-authorize-freshness)

Run the `@oauth-consent` e2e feature (`e2e/features/oauth/oauth-consent.feature`, real Dex, plus the updated `@oauth-authorize` and `@oauth-account` features) and record the results of the manual items 1-8 (ADR-033 section "Consent, freshness and refresh serialization", Manual verification): (1) Dex `auth_time` and `max_age` behaviour, (2) an IdP that emits `auth_time`, (3) Element Web login through the consent page, (4) FluffyChat, (5) the scripted parallel refresh, (6) `per_refresh` with an IdP client that issues no refresh token, (7) the consent page in a cross-origin iframe and a screen-reader pass, (8) the double-click proof of concept. Without an IdP `auth_time` the consent page shows a notice and `/account` device deletion / key-reset approval is unavailable (fail closed, release note aw). Note on the consent page (double-clickjacking mitigation, ADR-033 FR21, story consent-arming-hardening): the page carries ONE hash-pinned inline script, the shared `Nebu.Web.ArmScript` of the SSO confirmation page. Allow is rendered `aria-disabled` (never `disabled`) and becomes available 600 ms after real interaction elsewhere on the page (pointer movement, a key press, a wheel event, a touch, a focus move); a mouse click is then accepted only after the pointer travelled onto Allow, a keyboard activation only after the focus moved onto it. With JavaScript disabled (or blocked) Allow is unavailable (its `form` attribute points at no form) and the user can only Deny, so an environment that strips scripts cannot complete a login (fail closed). The consent page keeps `Cross-Origin-Opener-Policy: same-origin` (decision D5). Item (8) of the manual list is the double-click proof of concept.

### Manual verification before activation

Everything below fails closed in code and could not be run in the isolated build environment (no real IdP, browser, client app, load balancer or deployed host). Each item is defined in detail in the story / ADR-033 section named in brackets; the details are not repeated here. **Record the result of every item (who, date, version, observed behaviour) before `oauth_enabled` is flipped**, or consciously accept the open item in writing together with the "Accepted risks" below. Items of group A that concern client IPs are a precondition of the flip itself (see the activation steps), not a post-flip check.

**A. Load balancer, proxy and cluster**
- XFF append semantics of the load balancer (UpCloud `set_forwarded_headers`, Stackit ALB): does it APPEND the client address to (or overwrite) `X-Forwarded-For`? Decides whether `lb_real_ip_cidrs` may be set; a forward-only LB lets a client write the key. [ADR-033 "Trusted-proxy client IP", Manual verification; follow-up ap6]
- Source CIDR of the load balancer (exact `/32`; UpCloud output `lb_private_addresses`) for `lb_real_ip_cidrs`, and the actual peer addresses (`alb` proxy `.10`, `acme` host nginx seen as the compose gateway `.1`, Docker `ip_range`). [same; follow-up ap7]
- NEGATIVE spoof test, before the flip: a login with the forged header `X-Forwarded-For: 203.0.113.99` through the public endpoint over `https://` AND `http://` port 80, over IPv4 AND IPv6, and directly to the published ports `8008` / `8080` if reachable; `last_seen_ip` must never show it (the forged request fires the W1 server warning `client IP: a request carried X-Forwarded-For` on a directly reachable port: expected, not a failure, and never a reason to widen the trusted list). AND the POSITIVE test, which is equally gating (G3-2): two clients on different networks, through the real public path, must show DISTINCT real `last_seen_ip` values (not the LB / proxy address) and independent `429`s on `/login`; with `tls_mode = alb` and an empty `lb_real_ip_cidrs` they will not, and then `oauth_enabled` must NOT be flipped (all per-source caps become global: login denial of service by one anonymous source). [this document, "Client IP behind a reverse proxy"; ADR-033 "Trusted-proxy client IP"]
- No W2 line (`client IP: all <n> devices ...`) in the server log of the last 24 h and no client-IP `check` warning in `tofu plan`; a W1 line (`client IP: a request carried X-Forwarded-For`) only needs an explanation (your own negative test against a direct port, or a client-written header on a direct deployment, fires it) and must NEVER be silenced by widening `NEBU_TRUSTED_PROXY_CIDRS`: list only an exact proxy address you verified. [this document, "Client IP behind a reverse proxy", "Misconfiguration warnings"; story client-ip-misconfiguration-warnings]
- `8008` / `8080` are not reachable from the internet (bound to `127.0.0.1`); `docker network inspect` confirms the pinned subnet and nginx address; existing VMs were restarted (`nebu.service`) for the pinned subnet. [follow-up ap1, ap7]
- UpCloud `dynamic` certificate issuance (HTTP-01) works behind the HTTP-mode `http-80` frontend (otherwise revert `http-80` to TCP for `dynamic`); Stackit NLB source-address preservation for `acme` / `none`; TCP-mode load balancers without PROXY protocol lose the client IP and are not supported. [follow-up ap7, ap3]
- The proxy sends `X-Forwarded-Proto: https` (the consent, account and binding cookies are `Secure` / `__Host-`); two-node cache TTL (an `oauth_enabled` flip shows on both nodes within 2 s). [story oauth-hardening-hygiene, Manual verification; HY15]
- Per-source caps with the verified CIDR list: 21st registration for one host from one source answers `503`, another source `201`; after 300 abandoned authorize requests from another network a real login still works. [story oauth-dcr-abuse-hardening, Manual verification; AH12]

**B. IdP (Dex, Keycloak or the production IdP)**
- `auth_time`, `max_age=0` and `prompt=login` behaviour: does the id_token carry `auth_time`, is there a re-prompt (two logins in one browser)? Dex v2.45.1 reportedly omits `auth_time`; Keycloak emits it. Without it the consent page shows a notice and `/account` device deletion / key-reset approval show `freshness_unavailable` (release note aw). [story oauth-authorize-freshness, Manual verification 1-2; story oauth-client-revocation, Manual verification 1]
- Offline refresh token: with `oauth_idp_revalidation = per_refresh` the IdP client must issue a refresh token (`matrix_oidc_refresh_mode = offline`); an IdP client without one must give `server_error` and one WARNING. [Manual verification 6]
- Scripted parallel refresh: two parallel `POST /oauth2/token` refreshes of one refresh token against Dex (`refreshTokens.reuseInterval`) and against an IdP with reuse detection: no logout, one IdP redemption. [Manual verification 5]
- Admin re-authentication with the real admin IdP (an IdP that ignores `max_age=0`, for example Entra, fails closed: use the rpc command; `NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME` stays off in production). [story oauth-client-revocation; ADR-033 SO5]

**C. Clients**
- Element Web (Chrome, Firefox, Safari): login through the consent page; the `form-action` CSP must not block the redirect after Allow (custom schemes included); reload and back button behave per FR7 / FR12. [story oauth-authorize-freshness, Manual verification 3]
- FluffyChat / Dart SDK (Android Custom Tab, iOS ASWebAuthenticationSession): the consent POST, then the redirect to the private-use scheme, reaches the app; login and logout without `404` / `405` errors. [same, 4; story oauth-room-summary-unrecognized, Manual verification 2]
- Element X: consent, custom-scheme redirect, and the `/account` page in a system browser tab that sends fetch metadata (cross-signing reset approved end to end; needs an IdP `auth_time`). [story oauth-client-revocation, Manual verification 3]
- Double-click mitigation arming (FR21): from a test page `window.open` a popup and navigate the opener to a consent URL while double-clicking at the Allow position: the second click must not decide; also try the MULTI-GESTURE variant (a lure that first makes the user move the pointer and wait 600 ms, then asks for a second click at the Allow position without a new pointer movement onto Allow): it must not decide either (G3-5, reduced: closed for the parked-pointer lures; record the result); the moving-target "click game" variant (an attacker game whose click on target A opens the consent popup so that Allow sits where target B will be) is NOT covered: only the 600 ms dwell remains, record how it behaves; with JavaScript disabled Allow is inert and Deny works; a touch device and a screen reader (VoiceOver / TalkBack touch exploration) can reach Allow, hear the hint and allow after arming; the consent page in a cross-origin iframe is blocked. [stories oauth-authorize-freshness, Manual verification 7-8, and consent-arming-hardening]
- A popup-based web client through the consent page (COOP, decision D5 of consent-arming-hardening): the consent page keeps `Cross-Origin-Opener-Policy: same-origin`. Run the OAuth flow of a web client that uses a popup (`window.open` and `window.opener`, for example FluffyChat web if it supports OAuth, or `flutter_web_auth_2` on web) and record whether the login completes. If it hangs because `window.opener` is severed, a later decision drops COOP on the consent page (follow-up `cr`); not changed blind. Element Web (full-page redirect) and the native clients are not affected.
- Layout shift on the consent page: with Allow armed, a late layout change under a parked pointer (a resized window, a late-loading font) must not let a click through without a pointer movement onto Allow; the page announces "Move the pointer off and back onto Allow, then click." instead.
- Assistive-technology activation of the consent (and SSO confirmation) page, a MANUAL pre-activation gate (UX N1, consent-arming-hardening cycle 1): with VoiceOver (iOS and macOS), TalkBack, NVDA and JAWS, reach Allow, hear the hint, arm the page (the first interaction elsewhere, a key press, or a tap), and activate Allow. Many assistive technologies activate through a synthesized click with `detail` 0 or without a pointer move, which the arming script treats as a keyboard activation (the focus must have moved onto Allow after arming) or a pointer click (a movement onto Allow is required). Record for each AT whether Allow can be activated. If it fails, an AT path in the script is needed and that change needs Kassandra's review (the arming is a usability barrier, never loosened blind).
- Logout: legacy logout in Element Web A with an OAuth-aware client B alive (B keeps syncing, A's device leaves the session list), FluffyChat vs Element Web, a `500` logout still clears the local session, one `legacy logout` INFO line without token material. [story legacy-logout-per-device, Manual verification 1-4]
- Cross-signing reset: with a real client, through `/account` (see Element X above) after a fresh login. [story oauth-account-management; ADR-033 A14]
- `room_summary` / room preview: Element Web `#alias:server` link of a public room (preview + join), Element Web spaces (`/hierarchy`), FluffyChat `matrix.to` links (public and invite-only), the "registration disabled" message for `POST /register`, and the matrix-js-sdk `im.nheko.summary` fallback claim; list new `M_UNRECOGNIZED` console errors. [story oauth-room-summary-unrecognized, Manual verification 1-5]

**D. Admin**
- Real browsers, MANUAL (cannot be run by the pipeline; record the result before the flip): the admin actions need the browser to prove a user click. **Chrome and Firefox** send `Sec-Fetch-Site: same-origin`, `Sec-Fetch-Mode: navigate`, `Sec-Fetch-Dest: document` and `Sec-Fetch-User: ?1`; **Safari (macOS and iOS) sends the first three but NEVER `Sec-Fetch-User`** and proves the click through the hidden `_click_proof` field instead (story safari-fetch-metadata-compat). In EACH of current Chrome, Firefox and Safari: (1) a mouse click AND an Enter-key submit of the approve / revoke confirm pages, of the reject button and the bulk removal (with the native confirm dialog accepted, also when answered slowly), of both `/admin/config` SSO trust forms (click, and Enter in the text field of the origins form) and of the `/account` reset approval work through the reference nginx; (2) in Safari the DevTools network tab shows `_click_proof=1` in the POST body and no `Sec-Fetch-User` header, the action is carried out and no 403 appears; (3) in Safari with JavaScript disabled for the site (or the script blocked by a content blocker) the same button answers the NOTICE page "Please press the button again" (`/account`: the notice "Nothing was changed ..." on the reset page), nothing is changed, and re-enabling the script makes the action work without a new sign-in; (4) a `fetch()` POST and a hidden-iframe form submit to the revoke URL are refused in all three (403 page); (5) re-authentication works end to end (the 5-minute marker); (6) assistive technology in Safari: approve with VoiceOver (macOS and iOS), iOS Voice Control and Switch Control must carry the action out (their activations must count as trusted clicks, otherwise the notice page appears forever = a dead end for those users). [story oauth-client-revocation, Manual verification 1-2, 4; story safari-fetch-metadata-compat]
- **The privileged config forms (story admin-config-privileged-forms-sweep), MANUAL, per browser.** In EACH of current Safari, Firefox and Chrome: (1) the claim mapping page (`/admin/config/claim-mapping`) and the role mapping page (`/admin/config/role-mapping`): the form shows "Sign in again to save": it sends you through the IdP (fresh sign-in), you return to the page with the notice "Signed in again", the form now shows "Save" and the validity line, "Save" works and shows the success flash, and the link is back, one audit row (`oidc_claim_mapping_changed` / `admin_group_claim_changed`) appears; (2) the OIDC scopes and refresh mode forms save with ONE click and no sign-in (strict fetch metadata only), in Safari with the click proof, and with JavaScript blocked for the site in Safari they answer the notice page; (3) a `fetch()` POST of any of these forms (browser console) is refused with the 403 page, and the two mapping pages cannot be framed; (4) saving the SSO scheme list writes the audit row `sso_redirect_schemes_changed`; (5) the lock-out warning is read by a screen reader before the Save button and the recovery SQL of "Admin configuration forms and their protection" is tested on a test instance. [story admin-config-privileged-forms-sweep] **Atomic audit (story admin-config-audit-atomic), MANUAL, once on a test instance:** make the audit table unwritable (for example `REVOKE INSERT ON audit_log FROM nebu_app;` as the owner, restore it afterwards) and save the role mapping, a widened SSO scheme list and a widened scopes value: each answers "... not saved: the audit entry could not be written" and the stored value is unchanged; then clear the scheme list and the scopes and switch the refresh mode to online: each is saved and shows "saved, but the audit entry could not be written". Restore the grant and check that the next save writes its row again. **The remaining admin forms (story admin-forms-gate-sweep), MANUAL, per browser:** in EACH of current Safari, Firefox and Chrome: (1) the media settings page: the media policy and the storage target show "Sign in again to save" (one marker for the page: one sign-in, one save of either form): the link sends you through the IdP (fresh sign-in), you return to the page with the notice "Signed in again", both forms show "Save" and the validity line, "Save" works (enter the access key and the secret key, they are never filled in); the test connection button works without a sign-in, and a test connection to an endpoint other than the stored one with empty key fields says that the keys must be entered (the e2e feature `media-settings-gate` covers the media policy save with its fresh sign-in; the storage target and the test connection have NO e2e test); (2) delete a device, add and remove a room member, toggle auto-join on a room and a space, archive / unarchive a room, change a room's visibility, save the log retention, rename a device, create a room and a space: each works with ONE click (Safari with the click proof; with JavaScript blocked for the site in Safari each answers the notice page); (3) a `fetch()` POST of any of these forms (browser console) is refused with the 403 page; (4) the audit log shows `room_auto_join_changed` for a room toggle and `log_settings_changed` for a log retention save. **Role mapping self-lock-out guard (story role-mapping-self-lockout-guard), MANUAL, per browser:** on the role mapping page enter a group your own token does not hold, press Save, sign in at the IdP when asked: the page comes back (no second sign-in needed to correct it) with "not in your own sign-in token" under the field and the stored value is unchanged; then enter a group your token holds (check the claim path shown on the page against a decoded ID token of your IdP, including a nested path such as `realm_access.roles`) and save: it works. Check once with a real IdP that the groups claim of your admin token appears at the shown path.
- **OAuth switch checkbox flow (story admin-oauth-switch), MANUAL, per browser and on a running instance.** In EACH of current Safari, Firefox and Chrome: (1) `/admin/config` shows the section "OAuth 2.0 authorization server" with the status list (every item starts with `OK`, `Attention` or `Note`) and the honest text about what the server cannot check; (2) with OAuth off, enter a valid issuer, check "Offer the OAuth 2.0 API" WITHOUT the acknowledgement and press "Save OAuth settings": after the fresh sign-in the page refuses with the message under the acknowledgement checkbox and nothing changes; with an `http://` issuer the message under the issuer field says that OAuth cannot be switched on without a valid https issuer; (3) with the acknowledgement ticked the save succeeds, the flash says "OAuth settings saved", `curl <issuer>/_matrix/client/v1/auth_metadata` answers 200 and `/_matrix/client/versions` lists v1.15 on EVERY node within `NEBU_OAUTH_CONFIG_CACHE_MS`; (4) one `oauth_switch_changed` row appears in the audit log (actor, before / after); (5) the rollback on a running instance: uncheck the checkbox, save (sign in again when asked), observe `/versions` v1.1-v1.11 and `auth_metadata` 404 on every node, the OAuth session of a test client keeps working until its access token expires and then needs a new login, then `revoke_all_oauth_sessions` ends it; (6) a `fetch()` POST of the form (browser console) and a hidden-iframe submit are refused (403 page); in Safari with JavaScript disabled for the site the button answers the notice page and nothing changes; (7) with a screen reader (VoiceOver, NVDA) the status items are read with their word, the errors are announced and the acknowledgement checkbox is reachable; the section reflows at 320 px; (8) the status list is read honestly: with `NEBU_TRUSTED_PROXY_CIDRS` empty behind a proxy it shows `Attention`, and with a CIDR list it does NOT prove the load balancer (the positive client-IP test of group A is still done by hand). [story admin-oauth-switch]
- Registrations UI: badges for a `*.github.io` registration, bulk removal by domain and by age, native confirm, one `oauth_clients_bulk_removed` audit row, keyboard-only and screen-reader pass. [story oauth-dcr-abuse-hardening, Manual verification 2]
- Dedicated origin decision (SO8): serve Element Web on its own hostname, or acknowledge the shared-origin risk SO7 in writing ("Reverse proxy", "Accepted risks"); a dedicated ADMIN hostname is not possible yet (follow-up ba).
- Revoking a client with a live Element Web session logs Element Web out at its next request and removes the device. [story oauth-client-revocation, Manual verification 5]

**E. Operator rehearsals (on a test instance)**
- Signing-key rotation: `rotate_oauth_signing_key()` call 1, wait 15 minutes, call 2 while Element Web / FluffyChat sessions refresh (no logout, no id_token validation error); in staging also `replace_oauth_signing_key(:emergency)` (record which clients refetch the JWKS on an unknown `kid`). [story oauth-hardening-hygiene, Manual verification; "Rotating the id_token signing key"]
- `revoke_client` rehearsal: revoke a test client in the admin UI and with the rpc command; `bin/nebu rpc` works in the reference containers for `revoke_oauth_client`, `revoke_all_oauth_sessions` and the rotation functions. [story oauth-client-revocation, Manual verification 6; "Revoking a client"]
- Rollback rehearsal: switch off, observe `/versions` v1.1-v1.11 within the cache TTL, the forced re-login of OAuth sessions, then `revoke_all_oauth_sessions` (the rollback section below; activation step 5).
- Media retention windows (story media-cleanup-reads-media-config): on a test instance set `deleted_days` and `infected_days` to small values in the Admin UI, wait for (or trigger) the daily cleanup and check the `media_hard_deleted` audit rows (`retention_days` = the saved value) and the INFO line `retention deleted_days=N infected_days=N`; then damage the stored value on the test instance (`UPDATE media_config SET value = 'abc' WHERE key = 'deleted_days'`) and check that the next run deletes nothing and logs `retention config unavailable`.
- Unwritable audit table for the media retention values: on a test instance make the INSERT into `audit_log` fail for the runtime role, then shorten `deleted_days` in the Admin UI ("Failed to save media settings", the stored value unchanged, one ERROR `shortening refused` in the log) and lengthen it ("Media settings saved", the value changed, no audit row, one ERROR `applied without audit`); restore the privilege afterwards. [story media-retention-audit-atomic; "Admin configuration forms and their protection"]
- Acknowledge before the upgrade: media retention values saved earlier become effective (pre-check `SELECT` of "Media retention windows" run and the values judged).
- Acknowledge the release notes of "Accepted risks" (legacy SSO redirect confirmation residuals (G3-3), SO7, (s) re-scoped, (q), (al), aw, `NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME` off).

**F. Legacy SSO confirmation page (G3-3; section "Legacy SSO confirmation page")**
- Element Web on a listed origin (own `https://<server_name>`, `sso_redirect_allowed_origins` or an approved client's origin) signs in with the real IdP without the page; an unlisted https origin shows the page, Cancel ends the flow without a `loginToken` (check `POST /login` with the URL's token is not possible), Continue signs in.
- A popup-based web client (FluffyChat web) and a native client (Element Desktop `element://`, a loopback client) are not blocked; the page cannot be framed; Continue cannot be activated by a double-click lure (mouse, touch, keyboard).
- Saving the allowlist (`/admin/config`, "SSO redirect origins") and the scheme list needs a fresh admin sign-in (SEC delta gate X-1): the forms show "Sign in again to save", the link sends the admin through the IdP and back with the notice "Signed in again", and then Save works; a `fetch()` POST (browser console) is refused with the `403` page; `/admin/config` cannot be framed (also with a trailing slash). With an IdP that ignores `max_age=0` and omits `auth_time` the sign-in is the flow-only kind (SO5).
- The INFO line `matrix SSO: redirect confirmation shown host=...` appears for an unlisted host and carries no path, query, token or cookie; list the origins your users really use and record the list with the change record.

### Activation steps and smoke test

0a. **Emergency path.** On the target instance prove that you can switch OAuth off and recover the admin settings WITHOUT the Admin UI (`bin/nebu rpc 'IO.inspect(Nebu.Release.disable_oauth())'` on a test run, or psql; see "Admin configuration forms and their protection"): the UI switch needs a fresh sign-in, which fails when the IdP is down.
0. Before anything else: `NEBU_TRUSTED_PROXY_CIDRS` is configured (reference templates: derived by OpenTofu; own proxies: the list of YOUR proxies) AND BOTH tests of group A have passed on the real deployment: the NEGATIVE spoof test (forged `X-Forwarded-For` over `https`, `http` port 80, IPv4, IPv6 and the direct ports) and the POSITIVE test (two clients on different networks show DISTINCT real `last_seen_ip` values through the real public path). The negative test alone is not enough: with the `alb` topology and an empty `lb_real_ip_cidrs` all clients collapse to the load-balancer address, the spoof tests pass, and every per-source cap and per-IP bucket becomes global, so one anonymous source can lock every user out of OAuth login (consent cap 20 per source, authorize / account caps 300). **`tofu alb` with an empty `lb_real_ip_cidrs` = do NOT flip `oauth_enabled`.** Do not flip with an unverified or untested list. The `tofu plan` client-IP check (reference templates) must be clean and the server log must not show the W2 warning (`client IP: all <n> devices ...`) of the last 24 h. A W1 warning (`client IP: a request carried X-Forwarded-For`) only has to be explained (your own negative test against a direct port fires it, a client-written header on a direct deployment fires it) and must never be silenced by widening `NEBU_TRUSTED_PROXY_CIDRS`: list only an exact proxy address you verified. The absence of either warning does NOT replace the positive test.
1. **Flip.** Close every gate above and complete (or accept in writing) every item of "Manual verification before activation"; then set the two keys with the **Admin UI OR SQL**:

   - **Admin UI (the way for a running instance without a database console).** Open `/admin/config`, section "OAuth 2.0 authorization server": check the status list (an `Attention` item needs your decision, see "The Admin UI switch"), enter the issuer URL (the public https address of this server), check "Offer the OAuth 2.0 API", tick "I have read the activation checklist ...", press "Save OAuth settings" and sign in again when the IdP asks (you return to the page and must enter the values once more). The page confirms "OAuth settings saved"; every node follows within `NEBU_OAUTH_CONFIG_CACHE_MS`. **Rollback: uncheck the checkbox and save** (the kill switch; the running OAuth sessions stay valid until their access token expires, see the section on the kill switch, caches and rollback below). Unchecking switches OAuth off but does NOT remove the trust of the issuer origin in the legacy SSO login: if the issuer was set wrongly or to a host that is not your own, also clear the issuer field and save (or `Nebu.Release.disable_oauth()` and a corrected issuer).
   - **SQL (emergency path, IdP down, scripted setups).** `server_config(key, value TEXT, set_at BIGINT ms)` has RLS (`config_insert_only`, `config_update_mutable` allowlist, re-created last by migration 000049 with the keys of 000040 / 000042 / 000048 incl. both `oauth_*` keys), so run it as the runtime role `nebu_app` or the privileged owner. This path writes no `oauth_switch_changed` audit row, note the change in your change record:

   ```sql
   INSERT INTO server_config (key, value, set_at)
   VALUES ('oauth_issuer_url', 'https://chat.example.com', (extract(epoch from now()) * 1000)::bigint)
   ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at;
   INSERT INTO server_config (key, value, set_at)
   VALUES ('oauth_enabled', 'true', (extract(epoch from now()) * 1000)::bigint)
   ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, set_at = EXCLUDED.set_at;
   ```

2. Verify: `GET /_matrix/client/versions` lists `v1.15`; `auth_metadata` 200; `/.well-known/openid-configuration` 200; `/oauth2/jwks` 200; `GET /account` answers 302 to the IdP. With `NEBU_TRUSTED_PROXY_CIDRS` verified, two clients on different networks get independent per-source caps; without it the per-source caps act as small global caps (300 in-flight logins, 100 pending registrations, 20 consent requests per source (and 5 per user); the logs then carry the throttled line `per-source ... cap reached`, check the list).
3. Approve the first client registration in `/admin/oauth/registrations` (open its confirm page and press Approve; your IdP asks you to sign in again, see `NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME`); log in with Element Web and FluffyChat; call `/whoami`.
4. Log in a second time with the same client (a new registration per flow): the identical metadata maps to the same approved `client_id`, no new approval is required (a changed metadata hash is pending again).
5. Run a rollback rehearsal on a test instance: switch off, observe `/versions` v1.1-v1.11 and the OAuth session's forced re-login (below).
6. Keep the evidence of the manual verification with the change record; the flip is an operator decision, nothing in this repository performs it.

### Legacy SSO confirmation page (story legacy-sso-redirect-confirmation, epic SEC gate 3 G3-3)

**What changed (behaviour change, applies with `oauth_enabled` on or off).** After the IdP login of a legacy `m.login.sso` flow Nebu used to redirect straight to the client's `redirectUrl` with a 30 s `loginToken`. It now does that only for *listed* targets. For every other **https** target the callback mints no `loginToken`: it stores a pending confirmation (5 minutes, single use) and sends the browser to `GET /_matrix/client/v3/login/sso/confirm`, a page that names the target origin and the signed-in Matrix user and offers **Cancel** and **Continue**. Only Continue mints the `loginToken` and redirects (`303`). The redirect leg is stricter too: a `redirectUrl` with userinfo, backslashes, control characters or whitespace, hosts with characters outside `[a-z0-9-.]`, numeric host lookalikes (`0x7f.0.0.1`, `2130706433`) or more than 2048 bytes is a `400` (same bodies as for a rejected scheme).

**Unchanged (no page):** targets whose origin is *listed* (below), loopback `http://localhost|127.0.0.1[:port]`, the default deep-link schemes (`element`, `schildichat`, `im.fluffychat.auth`) and the schemes of the Admin setting "SSO redirect schemes". The UIA fallback is unchanged. The only change for listed targets: `loginToken` parameters already present in the `redirectUrl` are removed before the new one is appended (Matrix spec).

**Which origins are listed (exact origin match: `https`, host, port; no wildcards, no paths):**
1. `https://<server_name>` (the configured `NEBU_SERVER_NAME`, never the request `Host` header). **It must be an origin you control:** with `.well-known` delegation (the Matrix server name is the apex of your corporate site) the apex host receives `loginToken`s without confirmation.
2. The origin of `oauth_issuer_url`, when configured.
3. The registered https `redirect_uri`s of OAuth clients in status `approved` (an administrator approved them; `pending`, `rejected` and `revoked` never count; a database error counts as "not listed"). The match is by registered URI, NOT by origin: the `redirectUrl` must equal a registered URI or extend it at a path boundary (`/`, `?`, `#`); dot segments, encoded separators, `;` (matrix parameters such as `..;/`) and `%25` in the path never match (the user then sees the confirmation page). A legacy `loginToken` is a full, unscoped session, so approving a client also trusts those URIs for the legacy flow.
4. The operator list `server_config.sso_redirect_allowed_origins`, edited in the Admin UI under **/admin/config**, "SSO redirect origins" (comma separated `https://host[:port]` origins; wildcards, paths, userinfo and non-https are refused; changes reach every node within seconds through the same cache as the scheme list; every successful save writes the compliance audit row `sso_redirect_origins_changed` with the acting administrator and the normalized list).

**Who is affected:** legacy clients that run as a web app on an origin that is none of the above show the page on EVERY login until the origin is listed: a separately hosted Element Web (`https://element.example.com` while `server_name` is `example.com`), `https://app.element.io`, and SchildiChat, Cinny, Hydrogen or FluffyChat web builds on other hosts. Not affected: Element Web on `https://<server_name>` (the reference deployment), Element Desktop, SchildiChat and FluffyChat native, every loopback native client. Popup-based web clients keep working (the page sends no `Cross-Origin-Opener-Policy`).

**Saving the allowlist and the scheme list needs a fresh admin sign-in** (the allowlist save writes the audit row `sso_redirect_origins_changed`, the scheme list save `sso_redirect_schemes_changed`; the sibling forms are in "Admin configuration forms and their protection") (SEC delta gate X-1, story sso-origins-admin-hardening): both lists widen the trust of the legacy flow (an origin receives `loginToken`s without confirmation, an operator scheme is a direct redirect sink), so `POST /admin/config/sso-origins` and `/admin/config/sso-schemes` are protected like the approval of an OAuth client: strict fetch metadata (only a user-clicked form submit, no `fetch()`), a fresh re-authentication marker bound to `/admin/config` (consumed by a successful save, so every save needs its own sign-in; without it the form shows the link "Sign in again to save" to the IdP and back to `/admin/config`, where a notice says "Signed in again. Nothing is changed yet: enter your change and press Save", and a POST without the marker is refused and redirected to the IdP; the typed text is never replayed) and no framing of `/admin/config` (`frame-ancestors 'none'`, `X-Frame-Options: DENY`, `no-store`, decided on the routed path segments, so `/admin/config/` and `/admin//config` are covered; the claim / role mapping pages under `/admin/config/` keep `'self'`). The marker is bound to the page, not to one form (one sign-in, one save of either form). Registered approved-client URIs that themselves contain `;` or `%25` in their path always show the confirmation page. The same-origin caveat SO7 applies (a script on the shared origin that waits for an admin click). The other privilege-granting admin forms (claim / role mapping) are not changed by this story (follow-up `cw`).

**Operator procedure.** (1) After the upgrade, grep the server log for `matrix SSO: redirect confirmation shown host=<host>`: each distinct host is a target that users had to confirm; (2) list the origins you recognise in `/admin/config` -> "SSO redirect origins" (origin = `https://` + host, plus `:port` unless it is 443); (3) leave unknown hosts unlisted: the page is the protection, and `confirmed` / `declined` INFO lines show what users decide. The log lines carry the host only, never a path, query, `loginToken`, cookie or CSRF token. Rate limit: 600 requests per hour per client address and bucket on the confirm page (it shares the client-IP caveat of gate 1 / G3-2).

**Rolling deploys:** while old and new nodes run side by side, an old node still mints the `loginToken` directly for an unlisted https target and answers `GET /sso/confirm` with `404 M_UNRECOGNIZED`: prefer a stop-the-world or quickly completed rollout. The confirm page needs the original `Host` (including a non-default port) forwarded by the proxy; modern browsers also send `Sec-Fetch-Site: same-origin`, which the server accepts alongside the `Host` / `server_name` origin comparison.

**Migration 000048** re-creates the `config_update_mutable` policy of `server_config` with the keys `sso_extra_redirect_schemes` and `sso_redirect_allowed_origins` added. Before it, a SECOND save of the existing "SSO redirect schemes" form failed with a row-level-security error (the key was missing from the policy); the first save of a key always worked. The down migration restores the 000042 list.

**Manual verification (group F, release note).** With the real IdP and clients: (F1) Element Web on a listed origin signs in without the page and with a loginToken in the URL; (F2) an unlisted https origin shows the page and Cancel ends the flow without a token; Continue signs in; (F3) FluffyChat web (popup) and one native client (Element Desktop `element://`) are not blocked; (F4) the page cannot be framed and Continue is not clickable by a double-click lure (keyboard, mouse, touch).

### Revoking a client (story oauth-client-revocation, gate aj)

An approved client can be withdrawn at any time. **Admin UI:** `Approved Clients` (`/admin/oauth/clients`) lists every approved client with its verified host, approver, last use and the number of devices that are signed in; `Revoke` opens a confirm page that names the host, the device count and the consequences. Type the host (or the client id when no host is stored), optionally a reason, and press Revoke; your IdP asks you to sign in again first (the fresh sign-in is valid for 5 minutes and only for THIS client and action: one sign-in, one decision). Some IdPs (for example Microsoft Entra) ignore `max_age=0`: that shows as an endless "not confirmed" message and fails closed; use the rpc command below. The revocation is ONE database transaction together with its audit row (`oauth_client_revoked`; if the audit write fails, nothing happens): the client becomes `revoked`, every session of the client ends, its devices and their end-to-end encryption keys are deleted, its unused authorization codes, in-flight sign-ins and consent requests stop working, and bound raw-JWT credentials are denylisted after the commit. Users of that client are signed out at their next request and sign in again with another client (their cross-signing keys are per user and stay). Old tokens answer `M_UNKNOWN_TOKEN`; a token request of the client answers `invalid_client`.

**Final for the registration.** A `revoked` row is kept and listed under `Revoked Clients`. It keeps its metadata hash: a new Dynamic Client Registration with IDENTICAL metadata maps to the revoked row (the same `client_id`, status stays `revoked`, never pending again, no new approval possible). An application that should come back must register CHANGED metadata (a new hash, pending, a new approval). Owner-level DDL on `oauth_clients` is the only override and is not a supported operation. The guard trigger allows only `approved -> revoked`.

**Operator command line** (also when the admin IdP is down or cannot prove a fresh sign-in; shell access is the strong operator authentication). Run it in the RUNNING node, not with `eval`:

```bash
bin/nebu rpc 'IO.inspect(Nebu.Release.revoke_oauth_client("<client_id>", "<reason>"))'
# prints {:ok, %{devices: 3}} | {:error, :not_approved}  (rpc prints nothing by itself: keep the IO.inspect)
```

It does exactly what the UI does (actor `operator:rpc`, audit metadata `reauth: "rpc"`; the reason is optional: pass `nil`). Very large clients (more than about 10 000 devices) are revoked in one transaction with a 120 s timeout; a timeout rolls back completely and can be retried, but may never succeed for such a client (batched revoke is follow-up bb). While a revoke runs it holds the client row and every torn-down device row until it commits. Every request that waits on those rows is bounded PER REQUEST (a lock timeout of 300 ms, then an answer): token issuance and refresh rotation of that client answer `503` + `Retry-After` (they retry); under `per_refresh` (the default) the IdP lease claim and release of a refresh run under the same bound (`503` + `Retry-After: 5`, nothing is consumed, the refresh token stays valid until the revoke commits); `/oauth2/revoke`, `/logout` and `/logout/all` of that client's devices fail fast instead of waiting (`/oauth2/revoke`: `503` + `Retry-After: 5`); the `/sync` last-seen update and the pending-grace update of a locked row are skipped (best effort, they never wait). The overall load on the node stays proportional to the number of that client's active devices that keep retrying: each bounded request still holds a pool connection for up to 300 ms, so a very large revoke (thousands of devices) can degrade other traffic while it runs, and it still holds its rows for its whole duration. The full fix is the batched two-phase revoke (follow-up bb); until then revoke very large clients in a quiet period. Behind nginx's 60 s read timeout the admin page may show a gateway error although the revoke succeeds: reload `Revoked Clients`.

### Rotating the id_token signing key (story oauth-hardening-hygiene, HY11-HY13)

Nebu signs id_tokens with ONE active ES256 key (lazily generated at first use); the JWKS (`max-age=600`) publishes the active key, a pre-published `next` key and retired keys until their `not_after`. Rotate in TWO calls (run in the RUNNING node; `bin/nebu rpc` prints nothing by itself, keep the `IO.inspect`):

```bash
bin/nebu rpc 'IO.inspect(Nebu.Release.rotate_oauth_signing_key())'
# call 1 prints {:ok, {:published, "<kid>", "<activate_after ISO-8601>"}}: the new key is in the JWKS, it does not sign yet
# wait at least 15 minutes (the database refuses an earlier promotion), then run the SAME command again:
# call 2 prints {:ok, {:activated, "<new kid>", "<retired kid>"}} (or {:error, {:too_early, seconds_left}} = wait, no change)
```

Call 2 retires the old key (it stays in the JWKS for another 15 minutes, so id_tokens signed shortly before the switch still verify) and promotes the next key in one transaction. Each successful call writes one audit row (`oauth_signing_key_published` / `oauth_signing_key_rotated`, actor `operator:rpc`, kids only). `{:error, :next_key_unavailable}`: the next key can no longer be decrypted, use the emergency command. `{:error, :conflict}`: another operator's call changed the next key while this one waited (calls are serialized by a database advisory lock and the loser changes nothing); look at the JWKS and run it again if needed. No session is revoked and no client has to sign in again.

**Emergency replacement** (the active key cannot be decrypted, for instance after `NEBU_INTERNAL_SECRET` was changed; `ensure_active_key` then fails and the token endpoint answers 503):

```bash
bin/nebu rpc 'IO.inspect(Nebu.Release.replace_oauth_signing_key(:emergency))'
# prints {:ok, {:replaced, "<new kid>", "<old kid>"}}; any other argument prints {:error, :confirmation_required}
```

It retires the active key and any pending next key and installs a fresh active key at once (audit `oauth_signing_key_replaced`). Clients that cached the JWKS (at most 10 minutes) cannot verify new id_tokens until they refetch it, so expect a gap of up to 10 minutes; no session is revoked. Rotating `NEBU_INTERNAL_SECRET` requires this command afterwards (the signing key no longer decrypts) and logs out `per_refresh` OAuth sessions (the stored IdP refresh tokens no longer decrypt, follow-up (al); design in ADR-033 HY17). Scheduled / UI rotation is follow-up (bq).

### Kill switch, caches and rollback

**Switching off SUSPENDS OAuth, it does not revoke it.** The normal switch-off is the checkbox of the Admin UI (`/admin/config`, "OAuth 2.0 authorization server": uncheck "Offer the OAuth 2.0 API" and save; it needs a fresh sign-in and writes the audit row `oauth_switch_changed`). Emergency switch-off without the UI (needs database access, e.g. when the IdP is down so that no fresh sign-in is possible):

```sql
UPDATE server_config SET value = 'false', set_at = (extract(epoch from now()) * 1000)::bigint WHERE key = 'oauth_enabled';
```

It takes effect within `NEBU_OAUTH_CONFIG_CACHE_MS` (default 2 s) on every node: `/versions` lists v1.1-v1.11, `auth_metadata` answers 404 `M_UNRECOGNIZED`, the OAuth-aware login flags disappear, token / JWKS / openid-configuration / authorize / register / account answer 404, `POST /oauth2/revoke` stays live (R13) as does `/logout`. But the OAuth sessions themselves are untouched: `OidcPlug` keeps accepting OAuth access tokens until they expire (up to `oauth_access_token_ttl_seconds`, at most 3600 s; C16), the refresh answers the T22 404 without `error` (matrix-js-sdk: retryable, not a logout) and changes no row, and **re-enabling OAuth revives every stored, unexpired session, a stolen refresh token included, until its `session_expires_at`**.

**Rate limits in this area (story oauth-hardening-hygiene, HY3).** `GET /_matrix/client/v3/login` (the Matrix spec marks it rate limited) has its own per-source bucket, 300/min with a burst of 300 (`429 M_LIMIT_EXCEEDED` + `Retry-After`; not shared with `POST /login`); the live `GET /.well-known/openid-configuration` 600/min, burst 600 (`429 too_many_requests` + `Retry-After`; the disabled `404` takes no token). `auth_metadata`, `auth_issuer`, the unstable aliases and `/versions` are never rate limited (spec, load-balancer health checks); the per-node cache keeps them off the database. Behind a proxy the buckets are keyed on the client address only with `NEBU_TRUSTED_PROXY_CIDRS` set (see "Client IP behind a reverse proxy"); **wherever the client address is not resolved (no trusted CIDRs, a shared proxy peer) every client shares the `GET /login` bucket (300/min) in EVERY deployment, also with OAuth off**: set the CIDRs before upgrading such a deployment (the Helm chart has no value for it yet, follow-up bu).

**To really revoke** (compromise, or a rollback you do not intend to undo) add a step AFTER the switch-off, in the running node (story oauth-client-revocation, CR10; replaces the former `DELETE FROM matrix_sessions` runbook, which left devices, keys, JWT bindings and codes behind):

```bash
bin/nebu rpc 'IO.inspect(Nebu.Release.revoke_all_oauth_sessions())'
# prints {:ok, n}  (n = devices ended; a second run returns {:ok, 0}; {:error, _} = partial, run it again)
```

It ends EVERY OAuth session of every user with the same locked per-device teardown as `POST /oauth2/revoke` (sessions with their stored IdP refresh tokens, the device and its device / one-time / fallback keys, bound JWTs), in batches of 500, and writes ONE audit row `oauth_sessions_revoked_all` with the count. Clients stay `approved` (they may sign in again once OAuth is back on); legacy sessions and devices are untouched. For ONE device use the device delete of the admin user page (`/admin/users/<id>`). To withdraw one client and everything it holds, use "Revoking a client" above. There is no UI for revoke-all (follow-up bc). Tell users to log out of their OAuth clients manually and to log in again with legacy SSO: the two APIs are mutually incompatible, an OAuth session can NEVER continue as a legacy session, so an OAuth client cannot use the legacy login without a fresh login; waiting (a drain) does not change that. Communicate it before switching off.

What clients cache: the metadata `Cache-Control: public, max-age=259200` (3 days; Dart SDK 3 days, browsers, CDNs), the JWKS `max-age=600`, `/versions` is `no-store` but held in client memory per session (matrix-js-sdk until reload / token change). Clients that cached the metadata still try `/oauth2/*` for up to 3 days and get 404 (I-2).

**Registrations.** Only `pending` registrations are purged (never approved / rejected / revoked rows); a registration with an active session cannot be deleted (FK `ON DELETE RESTRICT`). Revoked rows are kept for good and are never re-approvable with the same metadata (see "Revoking a client").

### Accepted risks and release notes to acknowledge before activation

- **Legacy `m.login.sso` redirectUrl trust (epic SEC gate 3, G3-3; mitigated by the story `legacy-sso-redirect-confirmation`, residuals to acknowledge):** an https `redirectUrl` that is NOT listed now needs a click on the confirmation page (after the IdP login, before any `loginToken` exists). Residuals: (a) a user who clicks Continue on a page that names an attacker origin still hands over a full session (the page is a warning, not proof: train users, and list every origin you really use); (b) loopback `http://localhost|127.0.0.1[:port]` targets and the default deep-link / operator-configured custom schemes (`element`, `schildichat`, `im.fluffychat.auth`, ...) do NOT show the page: a malicious local process or a malicious app registered for such a scheme on the user's own device can still receive a `loginToken`; (c) `https://<server_name>` is trusted automatically and must be an origin the operator controls (with `.well-known` delegation the apex host receives tokens without confirmation); (d) every OAuth client the administrator approves also makes its registered https redirect URIs (and the paths below them) trusted legacy redirect targets, and a legacy `loginToken` yields a full, unscoped session; (e) no pre-redirect browser binding of the legacy flow (login CSRF, follow-up `ca`); (f) cross-node single use of the pending confirmation is best effort (`SsoStore`, same property as the `loginToken` store); (g) Continue needs JavaScript (no-JS browsers can only Cancel). It is still independent of `oauth_enabled` and not subject to the DCR approval (the older accepted risk of running both APIs in parallel; deprecation path C20). Row `G3-3` of the preconditions table.
- **Story 4 (I-1, I-5):** `POST /logout/all` needs no UIA (the Matrix spec: an access token alone deletes all devices and keys); GDPR erasure kills sessions after its commit but does not deactivate the user: deactivate before erasing.
- **Story 5 (I-2):** other nodes may accept a raw IdP JWT for up to 60 s after a failed denylist write (lookup cache TTL).
- **(q):** switching `oauth_idp_revalidation` from `off` to `per_refresh` revokes OAuth sessions without a stored IdP refresh token at their next refresh; IdP refresh load grows with the number of clients.
- **(ai):** switch-off suspends instead of revoking (above); `Nebu.Release.revoke_all_oauth_sessions/0` revokes everything on demand (rpc, no UI); an automatic revocation on switch-off is still a follow-up.
- **SO7 (story oauth-client-revocation; gate ag):** Element Web, `/account` and `/admin` share ONE origin in the reference deployments. The code stops fetch / XHR posts, hidden iframes (no framing of `/admin/oauth/*`), scripted `form.submit()` without a user activation (not on WebKit, see the click proof below), cross-site and same-site posts and stale admin sessions (strict fetch metadata and a fresh admin sign-in on approve / revoke, strict fetch metadata on the cross-signing reset approval). It does NOT stop a script in Element Web that waits for ANY user click on the shared origin (and a same-origin script needs no user click at all on the consent page and on the legacy SSO confirmation page: it can open the flow in a popup it controls and submit the decision through the popup DOM; for an Element Web XSS that is no escalation, it already holds the access token; SO8 removes the class) (it is same-origin with the approval pages; a click gives the page transient activation, so a scripted submit then carries every fetch-metadata header) after it read the confirm page, nor a re-authentication the admin completes at the IdP (the marker is bound to one client and action and single use, so one such sign-in authorizes one decision). An Element XSS already yields the user's access token: these checks protect the higher-trust actions only. Safari / WebKit never sends `Sec-Fetch-User`, so for WebKit user agents (and only for them) the click proof replaces it (story safari-fetch-metadata-compat): a hidden form field `_click_proof` that the shared script sets on a TRUSTED click (`event.isTrusted`); the server accepts it only together with strictly correct `Sec-Fetch-Site` / `-Mode` / `-Dest`. A script in the page can set that field itself, so on WebKit the residual is slightly wider than on Chrome / Firefox: it no longer even has to wait for a user click (Chrome / Firefox keep the unchanged rule: `Sec-Fetch-User: ?1` required, a forged field is ignored; the `User-Agent` of a navigation cannot be set by page script). Without the proof (script blocked, stale page) a WebKit browser gets a notice page, not an error. Browsers without fetch metadata at all (Safari before 16.4, a proxy that strips the `Sec-Fetch-*` headers) are locked out of the strict actions: approve, revoke, reject, bulk removal, the `/admin/config` SSO trust saves and the `/account` reset approval. Only a separate origin for Element Web removes the class: acknowledge the risk before `oauth_enabled` or move Element Web (see "Reverse proxy").
- **Double-click arming residual (G3-5; REDUCED in the server by story consent-arming-hardening: closed for the parked-pointer lures, not eliminated):** the consent page now uses the shared `Nebu.Web.ArmScript`: after arming, a mouse / pen click is accepted only after a pointer movement onto Allow, so a pointer parked on the Allow position (the multi-gesture lure) cannot decide. Accepted residuals: (click game) a moving-target game whose click on target A opens the consent popup so that Allow sits where target B will be: the pointer travels onto Allow like for a real user, so only the 600 ms dwell and the arming interaction remain; (touch) one touch elsewhere arms after 600 ms and a following tap on Allow is accepted, so a multi-tap lure with a known mobile layout can still land; (keyboard) a lure with pauses ("Tab, wait, Tab, Enter") can move the focus onto Allow after arming and press Enter; (D5) the consent page keeps COOP, so a popup-based web client loses `window.opener` (group C item, follow-up `cr`). The server never trusts the button state; the arming is a usability barrier. Follow-up `cp`. Manual verification group C records the PoC results.
- **`NEBU_ADMIN_REAUTH_ALLOW_MISSING_AUTH_TIME` (SO5):** the opt-out is off by default; where it is on (dev Dex), an IdP that silently reuses an SSO session lets the admin re-authentication prove nothing. Never set it in production with an IdP that has an SSO session; the root `docker-compose.yml` is a dev file and sets it for the dev Dex only (G3-6).
- **Story P5 (deploy templates, gate m / k / ap1 / ae):** new / changed template variables `compose_subnet`, `trusted_proxy_cidrs`, `lb_real_ip_cidrs` (UpCloud and Stackit); UpCloud `alb` / `dynamic` and Stackit `alb` now target VM port `8081` (nginx proxy) plus `80` (redirect / probe), the compose network is pinned (existing VMs need a `nebu.service` restart, `compose_subnet` must not overlap `network_cidr`), the published ports `8008` / `8080` are loopback-only except for `tls_mode = "none"`, and nginx logs without query strings. Not verifiable without a deployed environment (non-gating follow-ups): whether the UpCloud `set_forwarded_headers` action and the Stackit ALB APPEND to `X-Forwarded-For`, the LB source address to put into `lb_real_ip_cidrs` (no safe default; empty = shared bucket), UpCloud `dynamic` certificate issuance behind the HTTP-mode `http-80` frontend, Docker `ip_range` behaviour on the VM, the `acme` plain-HTTP vhost that proxies until certbot has succeeded (bootstrap window), Stackit NLB source-address preservation and the Linux peer addresses (`alb` `.10`, `acme` `127.0.0.1` seen as `.1`). Run the Manual verification (ADR-033) before `oauth_enabled`.
- **Story oauth-room-summary-unrecognized (gates ac / af):** unknown Matrix endpoints answer 404/405 `M_UNRECOGNIZED` without authentication (RU10): a request to an unimplemented path or method no longer answers `401 M_MISSING_TOKEN` / `404 M_NOT_FOUND`, and `POST` / `PUT` / `HEAD /_matrix/client/versions` answer `405` + `Allow` in both OAuth states (health checks must use `GET`). `POST /_matrix/client/v3/register` answers `403 M_FORBIDDEN` for everybody (RU10a; Element shows "registration disabled"). `GET /_matrix/client/v1/room_summary/{roomIdOrAlias}` is served locally (RU1-RU8, per-user rate limit 300/min, burst 60). Under follow-up (ae): `/_matrix/client/v3/versions` is not routed and now answers `404 M_UNRECOGNIZED` (it answered `401` before), so a health check that still probes it keeps failing; use `GET /_matrix/client/versions` (RU16). `GET /rooms/{id}/state[/...]` keeps `404 M_NOT_FOUND` (RU11a, follow-up bf).
- **Gate (s), re-scoped (phase-2 decision 2026-10-13):** `device_lists.changed` for the peers of a deleted device is NOT implemented. Nebu refuses encrypted rooms (ADR-011), so no peer encrypts to a device and a stale peer device list has no confidentiality effect; clients may show a deleted device in a session list until a reload. The gate is now "before encrypted rooms are allowed (ADR-011 lifted) and before any release that claims E2EE"; the story `device-lists-changed-on-deletion` stays in the backlog. Do not announce end-to-end encryption support while it is open.
- **Story client-ip-misconfiguration-warnings (G3-2 aids):** the comment edits in both reference `cloud-init.tftpl` files (nginx client-IP comment block) change the rendered `user_data`; existing VMs may show a replace diff on the next `tofu apply` (this branch already changes both templates substantially, story P5). New log lines: `client IP: a request carried X-Forwarded-For` (W1) and `client IP: all <n> devices ...` / `client IP: device address check failed: ...` (W2, Oban cron `37 */6 * * *`); new `check` block `client_ip_resolution` (`client_ip_check.tf`, warns on `tofu plan`). No migration, no new variable, `oauth_enabled` is not blocked in code (see "Client IP behind a reverse proxy", "Misconfiguration warnings").
- **Manual verification (above):** every item that needs a real IdP, browser, client app, load balancer or operator rehearsal is listed in "Manual verification before activation"; an item that is not run is an accepted risk of the operator, not a closed gate.

## Network Boundaries

```
External boundary (exposed to clients):
  Internet → [TLS 1.3] → Elixir application (Port 4000)

Internal boundary (Docker network, not exposed):
  Elixir application → [TLS] → PostgreSQL  (Port 5432)
  Elixir application → [S3/TLS] → MinIO    (Port 9000)
  (HTTP surface → domain logic is an in-process function call within the one app — no network hop)
```

## Makefile Targets

```makefile
make setup              # Generate .secrets/internal_secret, MinIO credentials, and dev credentials
make dev                # docker compose up (server, postgres, dex, minio)
make dev-reset-db       # Drop + recreate the database, apply the single seed migration (WARNING: destroys all data)
make build-server       # Docker multi-stage build for the Elixir application
make test-unit-elixir   # mix test in container
make test-integration   # Full Docker Compose stack + Godog Gherkin tests
```

`make test-e2e-element-ci`, `make test-e2e-admin-ci` and `make test-e2e-oauth-ci` run the three browser e2e suites of the CI jobs below (`scripts/e2e-ci.sh`).

## CI Pipeline (`.gitlab-ci.yml`)

**Which pipelines exist (`workflow:rules`).** A SemVer tag (release stage), every merge request pipeline, schedules, a manual "Run pipeline" (web / api), `main`, `release/*` and `hotfix/*`
branches, and `feature/*`, `bugfix/*`, `chore/*` branches **only while they have no open merge request** (`$CI_OPEN_MERGE_REQUESTS` empty). With an open merge request the merge request
pipeline is the one pipeline of a push: no duplicate branch + merge request pipeline. Before the first merge request exists the branch gets a branch pipeline, so a pushed branch is never untested
(the former rules created no pipeline at all for such a branch, so the unit tests silently did not run). A branch pipeline that was started by the push before the merge request was opened can still
finish next to the first merge request pipeline; both test the same commit.

**Elixir image.** `CI_ELIXIR_IMAGE` is `$CI_REGISTRY_IMAGE/ci-elixir:1.20`, built by `build-ci-elixir` from `docker/Dockerfile.ci.elixir` (`FROM elixir:1.20-alpine`, the same base as the production
image `server/Dockerfile`). The tag used to say 1.19 while the image contained 1.20. Every job uses the variable. To bump the Elixir minor, change the `FROM` and the variable in ONE commit: the changed Dockerfile
makes the merge request / branch / main pipeline build the image in the `build-ci-images` stage, before the `unit` stage pulls it. If the tag does not exist in the registry yet (new project, registry
cleanup), run **Run pipeline** on the branch (or main) and start the manual jobs `build-ci-elixir` and `build-ci-dex` once. `test-unit-elixir` compiles with `--force --warnings-as-errors` (a restored
`_build` cache would otherwise hide warnings) and needs no database; `test-unit-elixir-1-19` is a non-blocking compatibility lane on the public `elixir:1.19-alpine` image (`mix.exs` promises `~> 1.19`).

**Browser e2e jobs** (docker-tagged DinD runner, amd64, `scripts/e2e-ci.sh`, all `allow_failure: true` until the first green runs on the runner confirm the setup):

| Job | Stack | Scope | Relevant when a merge request / main pipeline changes | Start |
|---|---|---|---|---|
| `e2e-element-web` | plain http compose stack (`localhost:8008`, `:7070`, Dex) | project `element-web` (Element Web through the full OIDC code + PKCE flow) | `server/lib/nebu/matrix*`, `server/lib/nebu/web/**`, migrations, `e2e/**`, the Element / Dex files, compose files | manual (always) |
| `e2e-admin-ui` | the same | project `admin-ui` without the OAuth groups | `server/lib/nebu/admin*`, `web`, `media`, `matrix*`, migrations, `e2e/**`, Dex, compose files | manual (always) |
| `e2e-oauth-https` | `dev/tls`: nginx + local CA (generated in the job), ONE origin `https://nebu.localtest.me:7443`, `oauth_enabled=true`, issuer = that origin | `features/oauth/**`, `oauth-client-approvals`, `oauth-client-revocation`, `oauth-switch` | `server/lib/nebu/oauth*`, `admin*`, `web`, `matrix/sso*`, migrations, `e2e/**`, `dev/tls/**`, Dex, compose files | manual (always) |

A full run is 20-60 minutes and needs a docker-tagged DinD runner, so the three jobs are manual everywhere (like `integration-test`; an automatic job without such a runner stays `pending`, and a manual job never blocks); the middle column lists what each job can catch a regression in. On merge request and main pipelines they
start from the prebuilt `build-server-image` registry image (`NEBU_E2E_PREBUILT=1`, `docker-compose.ci.yml`); a branch pipeline builds the image in the DinD daemon.
Playwright runs in a container on the host network with `--add-host` entries for `dex.localtest.me` and `nebu.localtest.me` (no `/etc/hosts` edit), the image tag follows `@playwright/test` of `e2e/package-lock.json`
(the old target pinned 1.44 next to a 1.59 lockfile), `npm ci`, the direct-DB fixtures use `psql` against the published postgres port. The HTTPS job exists because the OAuth consent and account POSTs check their
`Origin` against the issuer origin: a fake issuer on `http://localhost` cannot satisfy that, a real https origin can (`NEBU_E2E_OAUTH_ISSUER`, `e2e/fixtures/oauth-issuer.ts`); Playwright ignores certificate
errors there and the client redirect targets (`*.e2e.example`, `localhost:53682`) are answered by local stub servers (`e2e/fixtures/client-stubs.ts`: Playwright cannot intercept the second hop of a
redirect). Scenarios that fail for a documented reason are tagged `@known-failure`, excluded from the default run and listed in `e2e/KNOWN-FAILURES.md` (`NEBU_E2E_TAGS='@known-failure'` runs exactly those).
Not verified without a runner: the DinD bind mounts of the project directory, the pulled image, the junit artifact paths and the job durations.

**Other job rules.** `secret-scan`, `verify-docs` and `test-unit-elixir` run on merge request and every branch pipeline; `validate-iac` / `validate-helm` only when `deploy/**` changed (always on `release/*`);
the `renovate` job (it used to be a hidden `.renovate` template that never ran) exists for scheduled pipelines with a `RENOVATE_TOKEN`; images are pinned (no `:latest` except `docker:latest` of the DinD jobs; a review convention, the former `scripts/verify-ci-config.sh` check was removed together with the GitHub workflow).
GitLab CI is the only pipeline: the GitHub repository is a read-only mirror of `main` (job `sync-github-mirror`, `scripts/mirror-to-github.sh`) and has no `.github/workflows`.

## Database Migration Strategy (Story 13-14)

### Release note: migration 000038 (matrix_sessions token hashing)

Migration `000038_matrix_sessions_token_hashing` replaces the plaintext `access_token` / `refresh_token` columns of
`matrix_sessions` by SHA-256 hashes and **deletes ALL Matrix sessions** (`TRUNCATE`, no backfill): every user has to log
in again once. The release **must be deployed stop-the-world** - stop all nodes, migrate, start the new version; during a
rolling deploy, old nodes still query the dropped plaintext column and reject every opaque token with 401 (logins 500).
A rollback (`.down.sql`) deletes all sessions again, and the previous release writes plaintext tokens once more.
The role in `NEBU_DB_URL_MIGRATE` (or `NEBU_DB_URL` as fallback) must hold the `TRUNCATE` privilege on `matrix_sessions`
(the table owner has it automatically; `nebu_app` itself only has SELECT/INSERT/UPDATE/DELETE). Runbook pre-check:

```sql
SELECT tableowner FROM pg_tables WHERE tablename = 'matrix_sessions';
```

The result must be the migration role (or that role must have been granted `TRUNCATE`).

**User impact (E2EE):** this release logs out EVERY device of EVERY user at once; clients receive 401 without
`soft_logout` and discard their local E2EE state. Nebu has no server-side key backup (`GET room_keys/version` returns 404; `POST room_keys/version` is only an
acceptance stub that answers `{"version":"1"}` and stores nothing, so that Element Web's first-login key setup does not end in
"Unable to set up keys": Element then shows a recovery key although NO room key is ever backed up on the server, and
`PUT room_keys/keys` stays `M_UNRECOGNIZED`; ADR-011 is only Proposed). If encrypted rooms are in use, announce a maintenance window, ask users to export their room
keys beforehand and re-import them after re-login; otherwise encrypted history becomes unreadable.

### Squashed Seed Migration

The application ships a **single seed migration** (raw SQL, e.g. `000001_init.up.sql`) that represents the complete current schema in its final state. The previous 49 incremental migration files (000002–000049) have been deleted. Migrations are applied by `Nebu.Release.migrate/0` (raw SQL run by the release before the app boots, ADR-018) — there is no golang-migrate and no ORM.

**Rationale:** Incremental migrations accumulated role-specific ownership transfers (`ALTER TABLE … OWNER TO nebu_migrate`) and backward-compatibility grants (`GRANT EXECUTE … TO nebu`) that required the `nebu_migrate` and `nebu` PostgreSQL roles to exist before migrations ran. On managed database services (Stackit PostgresFlex, AWS Aurora Serverless v2) where the runtime role cannot run `CREATE ROLE` DDL, this caused fresh deployments to fail at migration 24.

**Single-role model:** The squashed migration is designed to run as `nebu_app` (the runtime DB user). All objects are created by `nebu_app`; no ownership transfers or legacy grants are needed. On such deployments `nebu_app` owns `matrix_sessions` and therefore holds `TRUNCATE` for migration 000038; if an installation created the table under another role, use the pre-check above.

**Key characteristics of the seed migration:**

- Contains all 26+ tables, indexes, triggers, functions, and RLS policies in final state
- No references to `nebu_migrate` in ownership transfers or function grants
- No `GRANT EXECUTE … TO nebu` (legacy backward-compat grants removed)
- `NEBU_DB_URL` (pointing to `nebu_app`) is used for both migrations and runtime on fresh deployments; `NEBU_DB_URL_MIGRATE` is still accepted for backward compatibility but is no longer required

**The down migration** drops all tables and functions in reverse dependency order. Extensions (`pgcrypto`, `uuid-ossp`) are intentionally NOT dropped - they may be shared at the PostgreSQL server level.

### Post-Seed Incremental Migrations

After the seed migration `000001_init`, specific features and bugfixes may introduce new incremental migrations
(e.g., `000035_backfill_power_levels_events` for the sync-state-events-missing-fields bugfix). These are applied
in sequence after the seed migration; `Nebu.Release.migrate/0` runs all `.up.sql` files in numeric order at boot.
Each incremental migration pairs `.up.sql` (apply) and `.down.sql` (rollback) files. Incremental migrations are 
created only when schema changes or one-time data transformations are necessary; they follow the single-role `nebu_app` pattern
(no ownership transfers, no legacy grants).

**Local dev reset:**

```bash
make dev-reset-db   # docker compose down --volumes → recreate postgres → start server (runs migration on boot)
                    # WARNING: destroys all local data
```

After reset, `Nebu.Release.migrate/0` runs at boot and `GET /ready` reflects the applied schema version.

### Stackit PostgresFlex Role Provisioning

The Stackit OpenTofu module (`deploy/tofu/examples/stackit/database.tf`) provisions three PostgresFlex users:

| User | Purpose |
|---|---|
| `nebu_app` | Runtime role: owns all objects in the squashed migration; used for both migrations and application queries |
| `nebu_migrate` | Kept for backward compatibility with existing deployments that pass `NEBU_DB_URL_MIGRATE`. No longer required for fresh deployments. |
| `nebu` (legacy) | Placeholder required by the original migration history's `GRANT EXECUTE … TO nebu` statements. Not needed for fresh deployments using the squashed migration. |

On fresh Stackit deployments, only `nebu_app` is used. The `nebu_migrate` and `nebu` users are provisioned to avoid breaking existing environments that may reference them, but they do not connect at runtime.

## Multi-Stage Dockerfile

There is a single image — the Elixir/OTP release. No Go build stage exists anymore (ADR-021).

**Elixir application pattern:**
```dockerfile
FROM elixir:1.19-alpine AS builder
RUN MIX_ENV=prod mix release

FROM alpine:3.23 AS runtime
COPY --from=builder /app/_build/prod/rel/nebu ./
# Nebu.Release.migrate/0 runs raw-SQL migrations on boot, then the supervisor tree starts.
ENTRYPOINT ["./bin/nebu", "start"]
```

## Health Checks

```yaml
server:
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:4000/health"]
    interval: 10s
    timeout: 5s
    retries: 3
    start_period: 30s
  restart: always
```

Docker Compose uses liveness (`GET :4000/health`). Because everything runs in one node, there is no
gateway↔core stream-health signal to derive readiness from — the former GRÜN/GELB/ROT status applied
only to the removed gateway↔core gRPC boundary (ADR-021). `GET :4000/health` reports node and cluster
status (see Server Clustering).

## Secret Management

Secrets are never passed as environment variables directly. They are mounted via Docker Compose
secrets and referenced via `NEBU_*_FILE` environment variables pointing to the mounted file:

```bash
make setup   # generates .secrets/internal_secret, .secrets/minio_root_user,
             # .secrets/minio_root_password, .secrets/minio_app_access_key,
             # and .secrets/minio_app_secret_key via openssl rand
# docker-compose.yml mounts all five as Docker secrets
# Gateway reads internal secret via NEBU_INTERNAL_SECRET_FILE=/run/secrets/internal_secret
# MinIO reads root credentials via MINIO_ROOT_USER_FILE / MINIO_ROOT_PASSWORD_FILE
# Media Gateway reads app credentials via NEBU_MINIO_ACCESS_KEY_FILE / NEBU_MINIO_SECRET_KEY_FILE
# createbuckets creates the nebu-app MinIO user and attaches the nebu-app-policy (PutObject+GetObject only)
# WARNING: These are example credentials for local development only.
# Replace before first production start.
```

### MinIO IAM Hardening (Story 12.3)

The media gateway uses a dedicated `nebu-app` MinIO user with a least-privilege IAM policy:

```json
{
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:PutObject", "s3:GetObject"],
    "Resource": ["arn:aws:s3:::nebu-media/*"]
  }]
}
```

Intentionally absent: `s3:DeleteObject` (soft-delete only), `s3:ListBucket` (prevents enumeration), `s3:*` (no admin ops from app). The `createbuckets` init container creates and attaches this policy at startup. The media gateway runs as this user, never as the MinIO root. Root credentials are never passed to the media gateway.

Policy source: `dev/minio/nebu-app-policy.json`.

_Source: `_bmad-output/planning-artifacts/architecture.md`, §Infrastructure & Deployment, §Build-Container-Strategie, §Resilienz & Selbst-Heilung_

---

## Production Deployment (OpenTofu IaC)

Story 13-1 introduces a production-grade Infrastructure-as-Code layer under `deploy/`. Three target platforms are supported - see [ADR-014](adr/ADR-014-deployment-strategy-iac.md) for the full decision rationale.

> **IaC predates ADR-021 — updating to single-container topology is tracked follow-up.** The OpenTofu
> modules and Helm chart described below were authored when Nebu was a two-container deployment
> (`gateway` + `core`). They still provision a `gateway` service/deployment and a separate
> `media` service. Those resources now map onto the **single Elixir application container** (the
> `server` image), which serves the Matrix API, media, and Admin UI on port 4000; references to a "Go
> gateway", a separate "media gateway", port 8008, and the gateway↔core gRPC hop are historical and
> will be collapsed when the IaC is regenerated for the consolidated topology. Read the platform
> sections below with that mapping in mind.

### deploy/ Directory Structure

```
deploy/
  tofu/
    modules/
      nebu-shared/    # Shared variables, validations, outputs (no provider resources)
      nebu-aws/       # AWS: ECS Fargate + RDS + S3 + ACM (Story 13-2)
      nebu-stackit/   # STACKIT: VMs + Docker Compose + ALB + DBaaS (Story 13-3)
      nebu-k8s/       # Kubernetes: Helm Release wrapper (Story 13-4)
    examples/
      aws/            # AWS quick-start root module
      stackit/        # STACKIT quick-start root module
      k8s/            # Kubernetes quick-start root module
  helm/
    nebu/             # Standalone Helm Chart (usable without OpenTofu)
```

### Platform Targets

| Platform | Mechanism | Database | Backend |
|---|---|---|---|
| AWS | ECS Fargate + Aurora Serverless v2 | AWS Aurora PostgreSQL 16 (Serverless v2) | S3 + DynamoDB |
| STACKIT | VMs + Docker Compose + ALB | STACKIT PostgresFlex (managed PostgreSQL 16) | STACKIT Object Storage (S3-compatible) |
| UpCloud | VMs + Docker Compose + ALB | UpCloud Managed PostgreSQL | UpCloud Managed Object Storage (S3-compatible) |
| Kubernetes | Helm Chart (`deploy/helm/nebu/`) | External (operator-provided) | S3-compatible or PostgreSQL |

### Local IaC Validation

```bash
make test-iac-validate   # tofu fmt -check + tofu validate (all examples, no cloud credentials)
```

Equivalent CI gate: `validate-iac` job in `.gitlab-ci.yml` (runs on every push touching `deploy/**`).

### Shared Module: nebu-shared

`deploy/tofu/modules/nebu-shared/` defines shared input variables consumed by all platform modules: `nebu_version`, `domain_name`, `admin_email`, `postgres_db_name`, `image_registry`. All variables carry validation constraints (non-empty checks, semver regex for `nebu_version`).

### AWS Networking Module (nebu-aws)

`deploy/tofu/modules/nebu-aws/network.tf` provisions the AWS network foundation: one VPC, two public and two private subnets across two AZs, a single NAT Gateway (cost-optimized; one per AZ for HA production), and scoped security groups for ALB (80/443 from internet), ECS (ports 8008 + 9000 from ALB SG), and RDS (5432 from ECS SG only, egress limited to VPC CIDR). Resource names incorporate the `environment` variable (e.g. `nebu-prod-alb-sg`) for multi-environment deployments.

### AWS Database Module (nebu-aws - database.tf)

`deploy/tofu/modules/nebu-aws/database.tf` provisions the Aurora Serverless v2 layer (Story 13-8 - replaces the previous RDS Multi-AZ `aws_db_instance`):

- `aws_db_subnet_group` - uses private subnets from network.tf (no public access); retained as Aurora clusters also require DB subnet groups
- `aws_rds_cluster` - Aurora PostgreSQL 16.6, `engine_mode = "provisioned"` (Serverless v2 requirement - NOT `"serverless"`), storage encrypted, 7-day automated backups. Serverless v2 scaling is controlled by the `serverlessv2_scaling_configuration` block:
  - `min_capacity = 0` (default dev) - scales to zero and auto-pauses after 1 hour idle (`seconds_until_auto_pause = 3600`). Set `min_capacity = 0.5` for production to avoid cold-start latency.
  - `max_capacity = 4` (default) - sufficient for expected Nebu MVP load (approx. 2 vCPU equivalent). Increase for high-traffic production.
- `aws_rds_cluster_instance` - one instance per cluster, `instance_class = "db.serverless"` (required for Serverless v2); Performance Insights enabled explicitly (7-day retention).
- DB master password: `var.db_password` (sensitive, minimum 8 chars). Secrets Manager integration is provided via `secrets.tf`.
- `db_endpoint` output references `aws_rds_cluster.this.endpoint` (writer endpoint) - Aurora clusters expose a dedicated writer endpoint; the reader endpoint is separate and not used for Nebu's primary DB connection.

Key variables: `aurora_min_capacity` (default `0`), `aurora_max_capacity` (default `4`), `db_password`, `skip_final_snapshot` (default `true` for dev). The former `db_instance_class` and `enable_performance_insights` variables have been removed - Aurora Serverless v2 uses a fixed `db.serverless` class and enables Performance Insights by default.

**Cost model:** Aurora Serverless v2 charges per ACU-second consumed. At `min_capacity = 0`, a completely idle cluster costs near zero (vs. ~$50–100/month for the previous always-on `db.t3.medium` Multi-AZ instance).

### AWS ALB Module (nebu-aws - alb.tf)

`deploy/tofu/modules/nebu-aws/alb.tf` provisions the internet-facing Application Load Balancer:

- `aws_lb` - internet-facing ALB, placed in public subnets, `drop_invalid_header_fields = true` (header injection protection)
- `aws_lb_target_group.gateway` - target type `ip` (required for Fargate awsvpc networking), port 8008, health check on `GET /_matrix/client/versions` (HTTP 200; follow-up (ae) fixed by story P5: the former `/_matrix/client/v3/versions` is not routed and answers `404 M_UNRECOGNIZED`, RU16)
- `aws_lb_listener.https` - port 443, TLS policy `ELBSecurityPolicy-TLS13-1-2-2021-06` (TLS 1.3 minimum), ACM certificate via `var.acm_certificate_arn`, forwards to gateway target group
- `aws_lb_listener.http_redirect` - port 80, permanent `HTTP_301` redirect to HTTPS/443; no plaintext traffic ever reaches the gateway

Module outputs added: `alb_dns_name`, `alb_zone_id` (for Route 53 ALIAS records).

Key variable: `acm_certificate_arn` - required for `tofu apply`; empty string is accepted for `tofu validate` only.

### AWS Secrets Manager Module (nebu-aws - secrets.tf)

`deploy/tofu/modules/nebu-aws/secrets.tf` provisions all Nebu runtime credentials as individual Secrets Manager secrets under the `nebu/${environment}/` namespace:

| Secret path | Purpose |
|---|---|
| `nebu/{env}/db_url` | Full PostgreSQL DSN (used by gateway + server) |
| `nebu/{env}/db_password` | RDS master password (plain string; kept separate for RDS rotation support) |
| `nebu/{env}/internal_secret` | PSK for gateway ↔ server node registration (ADR-008) |
| `nebu/{env}/oidc_client_secret` | OIDC client secret for identity provider registration |
| `nebu/{env}/oidc_issuer` | OIDC issuer URL |
| `nebu/{env}/release_cookie` | Erlang distribution cookie for OTP cluster authentication |

All `aws_secretsmanager_secret_version` resources are provisioned with `PLACEHOLDER_*` initial values and `lifecycle { ignore_changes = [secret_string] }` - preventing `tofu apply` from overwriting operator-rotated values. Operators must set real values before go-live (see RUNBOOK.md).

### AWS Compute Module (nebu-aws - compute.tf)

`deploy/tofu/modules/nebu-aws/compute.tf` provisions the full ECS Fargate compute layer:

- `aws_ecs_cluster` - Fargate cluster with Container Insights enabled (`"nebu-${environment}"`)
- `aws_iam_role.ecs_task_execution` - Task execution role with `AmazonECSTaskExecutionRolePolicy` + inline policy for `secretsmanager:GetSecretValue` scoped to `arn:aws:secretsmanager:*:*:secret:nebu/${environment}/*` (least-privilege; no wildcard resource)
- `aws_cloudwatch_log_group` - `/ecs/nebu-{env}-gateway` and `/ecs/nebu-{env}-server`, 30-day retention
- `aws_ecs_task_definition.gateway` - image `{registry}/nebu-gateway:{version}`, CPU 256 / Memory 512, port 8008, health check `GET /_matrix/client/versions` (follow-up (ae) fixed by story P5; the dependency-free `/health` also exists), `secrets` field references individual Secrets Manager ARNs for `NEBU_DB_URL`, `NEBU_OIDC_ISSUER`, `NEBU_OIDC_CLIENT_SECRET`, `NEBU_INTERNAL_SECRET`
- `aws_ecs_task_definition.server` - image `{registry}/nebu-server:{version}`, CPU 256 / Memory 512, port 9000, health check `GET /health`, `secrets` field references for `DATABASE_URL`, `RELEASE_COOKIE`, `NEBU_INTERNAL_SECRET`
- `aws_ecs_service.gateway` - Fargate service in private subnets, attached to the ALB target group (port 8008), `lifecycle { ignore_changes = [task_definition, desired_count] }` for GitOps rolling deployments
- `aws_ecs_service.server` - Fargate service in private subnets (no ALB attachment; accessed by gateway via gRPC on port 9000 within the VPC)

**Security invariants:** No `environment` field used for secrets in any task definition - all sensitive values are injected exclusively via the `secrets` field with Secrets Manager ARNs. IAM permissions are scoped to the namespace `nebu/${environment}/*` only.

Key variables: `aws_region` (CloudWatch Logs), `image_registry`, `nebu_version`, `acm_certificate_arn`, `ecs_desired_count` (default 1).

Module outputs: `ecs_cluster_arn`, `db_endpoint`, `task_execution_role_arn`, `alb_dns_name`, `alb_zone_id`.

### AWS Deployment Topology (Complete)

```
Internet
  │ HTTPS/443 (TLS 1.3)
  ▼
aws_lb (ALB, internet-facing)
  │ port 443 → aws_lb_listener.https → aws_lb_target_group.gateway (port 8008)
  │ port 80  → aws_lb_listener.http_redirect (HTTP 301 → HTTPS)
  ▼
aws_ecs_service.gateway (private subnets, ECS Fargate, no public IP)
  │ gRPC port 9000 (VPC-internal, ECS SG)
  ▼
aws_ecs_service.server (private subnets, ECS Fargate, no public IP)
  │ port 5432 (private subnets, RDS SG)
  ▼
aws_rds_cluster (Aurora PostgreSQL 16, Serverless v2, private subnets)
  ├── aws_rds_cluster_instance (db.serverless - scales 0–4 ACUs)
  └── writer endpoint: aws_rds_cluster.this.endpoint (port 5432)

Secrets Manager (nebu/{env}/*) ──► ECS task execution role (secretsmanager:GetSecretValue)
                                        │
                              injected into gateway + server containers
                              via ECS secrets field at task start
```

Day-2 operations (rolling updates, secret rotation, teardown) are documented in `deploy/tofu/examples/aws/RUNBOOK.md`.

### Stackit VM + Networking Module (nebu-stackit - 13-3a)

`deploy/tofu/examples/stackit/main.tf` provisions the STACKIT compute and network foundation:

- `stackit_network` - private routed network with configurable CIDR (`var.network_cidr`, default `10.0.0.0/24`)
- `stackit_security_group` + rules - stateful SG with inbound rules for 443 (HTTPS), 8008 (Matrix API), 22 (SSH); egress unrestricted
- `stackit_network_interface` - VM NIC attached to the network and SG
- `stackit_key_pair` - account-level SSH key pair (global resource; no `project_id`)
- `stackit_server` - Ubuntu 24.04 LTS VM; machine type via `var.vm_plan_id` (default `g2i.2`); AZ via `var.availability_zone` (default `eu01-1`)
- `stackit_public_ip` - Floating IP associated to the VM NIC. If the VM is recreated, re-attach manually via STACKIT portal or `stackit beta network-interface public-ip attach`
- `stackit_application_load_balancer` (`tls_mode = "alb"`, story P5 state) - HTTP-level ALB, TLS terminated at the ALB: listener `https-443` (`PROTOCOL_HTTPS`) → target pool `matrix-api` on VM port `8081`, listener `http-80` (`PROTOCOL_HTTP`) → pool `matrix-api-http` on VM port `80` (nginx redirects to https); both pools health-check `GET /_matrix/client/versions` (HTTP 200); `X-Forwarded-For` is produced by the ALB (verify it APPENDS before setting `lb_real_ip_cidrs`)
- `stackit_loadbalancer` (`tls_mode = "none"` / `"acme"`) - NLB with `PROTOCOL_TCP` listener on port 443 → target pool on VM port 8008 (`none`) or 443 (`acme`, plus port 80 → 80 for the redirect / certbot); health check is TCP-only (no HTTP path checks); no `X-Forwarded-For`; plan via `var.alb_plan_id` (default `p10`)

**HTTPS at ALB (upgrade path):** `enable_beta_resources = true` is already set in the provider block. Once `stackit` provider >= 0.96 exposes `PROTOCOL_HTTPS` in its stable schema, change the listener protocol to `PROTOCOL_HTTPS` and set `certificate_reference.name = var.stackit_tls_certificate_arn` (Stackit-managed certificate ARN). Until then, TLS is terminated at the gateway on port 8008.

**Authentication:** provider uses `service_account_key_path` (JSON key file) instead of a token. Path configured via `var.stackit_key_path` (sensitive).

Key variables: `stackit_project_id`, `stackit_key_path`, `ssh_public_key`, `ubuntu_image_id`, `network_cidr`, `availability_zone`, `vm_plan_id`, `alb_plan_id`, `stackit_tls_certificate_arn`.

### Stackit Managed Database (nebu-stackit - Story 13-8)

`deploy/tofu/examples/stackit/main.tf` provisions a dedicated STACKIT PostgresFlex instance alongside the application VM. This replaces the previous `postgres:16-alpine` container bundled in docker-compose.

**Resources provisioned:**

- `stackit_postgresflex_instance.nebu` - managed PostgreSQL 16 cluster with daily automated backups (`0 2 * * *` UTC), configurable replicas (`var.postgres_replicas`, default `1`; use `3` for production HA), and ACL locked to the VM's private network CIDR (`var.network_cidr`) - no public exposure
- `stackit_postgresflex_user.nebu` (`nebu_app`) - application user with `["login"]` role; owns the `nebu` database
- `stackit_postgresflex_user.keycloak` (`keycloak_app`) - dedicated Keycloak user with `["login"]` role; owns the `keycloak` database. Using separate DB users per application is a defence-in-depth measure: a compromise of the Nebu application user does not grant access to Keycloak data.
- `stackit_postgresflex_database.nebu` - `nebu` database, owner `nebu_app`
- `stackit_postgresflex_database.keycloak` - `keycloak` database, owner `keycloak_app`

PostgresFlex connection details (`host`, `port`, `username`, `password`) are computed by the provider after instance creation and passed directly into the cloud-init template as `pg_*` / `kc_*` variables. The password is **not** exposed as a Tofu output - operators retrieve it from Terraform state or via the STACKIT portal.

**Stackit Sizing Variables:**

| Variable | Default | Production recommendation |
|---|---|---|
| `postgres_replicas` | `1` | `3` (HA replication) |
| `postgres_cpu` | `1` | 2+ (depending on load) |
| `postgres_ram` | `4` GB | 8+ GB |
| `postgres_storage_size` | `20` GB | 50+ GB |

### Stackit Media Gateway Support (nebu-stackit - Media Gateway StackIT ObjectStore Story)

`deploy/tofu/examples/stackit/` now supports an optional Media Gateway deployment using StackIT Object Storage (S3-compatible) as the storage backend. Media Gateway is controlled by the `enable_media_gateway` variable.

**Resources provisioned when `enable_media_gateway = true`:**

- `stackit_objectstorage_bucket` - optionally creates an S3 bucket in StackIT Object Storage (if not already present)
- Docker Secrets for S3 credentials (`s3_access_key`, `s3_secret_key`) written to `/opt/nebu/.secrets/` with mode `0600`
- `media` Docker Compose service on port 8009 (exposed on loopback `127.0.0.1:8009` only)
- nginx routing rules for `/_matrix/media/` → media service (both TLS and non-TLS modes)

**Configuration Variables:**

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `enable_media_gateway` | bool | `false` | Deploy the media gateway service |
| `s3_access_key` | string (sensitive) | `""` | Access key for StackIT Object Store (required when enabled) |
| `s3_secret_key` | string (sensitive) | `""` | Secret key for StackIT Object Store (required when enabled) |
| `s3_endpoint` | string | `"object.storage.eu01.onstackit.cloud"` | S3 endpoint hostname (without `https://` prefix) |
| `s3_bucket` | string | `"nebu-media"` | S3 bucket name for media storage |
| `media_cpu_limit` | string | `"0.50"` | CPU limit for media gateway container |
| `media_memory_limit` | string | `"256m"` | Memory limit for media gateway container |

**Media Gateway Environment Variables (set via cloud-init):**

The media service receives the following configuration:

```
NEBU_SERVER_NAME           — From Stackit deployment
NEBU_DB_URL                — PostgresFlex connection string
NEBU_STORAGE_BACKEND       — Fixed: "minio" (StackIT Object Store is MinIO-compatible)
NEBU_MINIO_ENDPOINT        — From s3_endpoint variable
NEBU_MINIO_ACCESS_KEY_FILE — /run/secrets/s3_access_key (Docker Secret)
NEBU_MINIO_SECRET_KEY_FILE — /run/secrets/s3_secret_key (Docker Secret)
NEBU_MINIO_BUCKET          — From s3_bucket variable
NEBU_MINIO_USE_SSL         — "true" (StackIT Object Store requires TLS)
NEBU_OIDC_ISSUER           — From deployment configuration
NEBU_OIDC_CLIENT_ID        — From deployment configuration
NEBU_TRUSTED_PROXY_CIDRS    — set by the templates for tls_mode acme / alb (gate m, story P5: pinned proxy /32 or compose gateway /32, override via trusted_proxy_cidrs); for tls_mode none it is not set by the templates yet (no proxy; gate m, story P5, public 8008 target); explicit proxy CIDR allowlist for client-IP resolution (see "Client IP behind a reverse proxy"); the legacy NEBU_TRUSTED_PROXY is not read
```

**S3 Client Configuration (media/cmd/media/main.go):**

Media storage uses path-style bucket lookup for StackIT Object Store compatibility, translating bucket references to path-style S3 URLs (`https://endpoint/bucket/key`) instead of virtual-hosted URLs. (In the consolidated topology this is `Nebu.Media.Storage` via ExAws/Finch inside the single application; the historical IaC variables still describe a separate media service.)

**nginx Routing (when `enable_media_gateway = true`):**

| TLS mode | nginx behaviour |
|---|---|
| `enable_tls = true` (with ACME) | `https://<server_name>/_matrix/media/` → `http://media:8009` via Docker network |
| `enable_tls = false` | `http://<server_name>:8008/_matrix/media/` → `http://127.0.0.1:8009` on loopback (no TLS termination) |

Both routes set `client_max_body_size 50m` to allow large file uploads.

**Lifecycle - When Media Gateway is Disabled:**

When `enable_media_gateway = false` (default), no S3 buckets are created and the media service is absent from the docker-compose.yml. Operators can enable it later by setting `enable_media_gateway = true` and re-applying the Tofu configuration.

### Stackit OIDC Deployment Profiles (nebu-stackit - Story 13-9)

The Stackit deployment supports two OIDC profiles selected via `var.oidc_mode`:

| `oidc_mode` | Bundled IdP | Use case |
|---|---|---|
| `"dex"` | Dex IdP sidecar (`dexidp/dex:v2.45.1`) | Test, demo, integration environments |
| `"external"` _(default)_ | None | Production - operator provides an external OIDC provider |

**`"dex"` profile:**
- Dex runs as a Docker Compose sidecar on port 5556 with a static in-memory config (no database).
- `/opt/nebu/dex/config.yaml` is written at boot (mode `0600`) with a static client (`nebu-gateway`) and a static password user (`operator@example.com`).
- `effective_oidc_issuer` is auto-derived as `http://<server_name>:5556/dex`; the gateway resolves Dex via Docker hairpin NAT (Linux SNAT/masquerade - no extra routing required).
- A conditional SG rule `inbound_dex` opens port 5556 to `var.dex_allowed_cidr` (default `0.0.0.0/0` for demos; restrict to VPN/developer CIDR in shared environments).
- `var.dex_static_password_hash` (required when `oidc_mode = "dex"`) must be a bcrypt hash (`$2a$`/`$2b$`/`$2y$` prefix). Generate with: `htpasswd -bnBC 12 '' 'yourpassword' | tr -d ':' | sed 's/$2y/$2a/'`.
- Expected `docker compose ps` output: `dex` (healthy), `server` (healthy), `gateway` (healthy).

**`"external"` profile:**
- No bundled IdP is deployed.
- `var.oidc_issuer` (required, non-empty) is passed directly into `.env` as `NEBU_OIDC_ISSUER`.
- `var.oidc_client_secret` must match the secret registered in the external OIDC provider.
- Expected `docker compose ps` output: `server` (healthy), `gateway` (healthy).

**Keycloak is fully removed in both profiles.** `stackit_postgresflex_user.keycloak` and `stackit_postgresflex_database.keycloak` no longer exist. There are no Keycloak-specific docker-compose services or secrets.

**New variables (Story 13-9):**

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `oidc_mode` | string | `"external"` | Profile selection; validated against `["dex", "external"]` |
| `dex_allowed_cidr` | string | `"0.0.0.0/0"` | Source CIDR for SG rule on Dex port 5556 (dex mode only) |
| `dex_static_password_hash` | string (sensitive) | `null` | bcrypt hash for Dex static user; required when `oidc_mode = "dex"` |

A `lifecycle { precondition }` block on `stackit_server.nebu` enforces: `oidc_mode == "dex" → dex_static_password_hash != null` and `oidc_mode == "external" → length(oidc_issuer) > 0`.

### DNS Mode - `dns_mode` variable (nebu-aws + nebu-stackit - Story 13-10)

Both the AWS and Stackit deployment examples support a `dns_mode` variable that controls whether OpenTofu creates DNS records automatically or leaves DNS registration to the operator.

| `dns_mode` | AWS behaviour | Stackit behaviour |
|---|---|---|
| `"external"` _(default)_ | No DNS resources created. `dns_name` output holds the ALB DNS hostname for manual CNAME/ALIAS registration. | No DNS resources created. `dns_name` output holds the floating IP for manual A-record registration. |
| `"default"` | Creates `data.aws_route53_zone` + `aws_route53_record` (ALIAS A-record) in Route 53, guarded by `count = 1`. Requires the hosted zone for `var.domain_name` to exist in the AWS account with an exact name match. | Creates `stackit_dns_zone` + `stackit_dns_record_set.nebu` (A-record) for `var.server_name → floating IP`, guarded by `count = 1`. |

Default is `"external"` to prevent accidental DNS changes on existing deployments.

**Stackit-only: `dex_subdomain_enabled`**

When `dns_mode = "default"` and `dex_subdomain_enabled = true`, an additional `stackit_dns_record_set.dex` resource creates a `dex.<server_name>` A-record pointing to the same floating IP. This lays groundwork for future host-based Dex routing (see story 13-9 dev notes). The variable is validated - setting it to `true` when `dns_mode = "external"` raises a validation error at plan time.

**Stackit-only: `dns_contact_email`**

An optional `dns_contact_email` variable (default `""`) sets the `contact_email` on the `stackit_dns_zone` resource. When empty, the field is omitted via null-coalescing (`var.dns_contact_email != "" ? var.dns_contact_email : null`).

**AWS: `dns_name` output**

A new `deploy/tofu/examples/aws/outputs.tf` exports `dns_name = module.nebu_aws.alb_dns_name`. Operators using `dns_mode = "external"` run `tofu output dns_name` to retrieve the ALB hostname to register as a CNAME. Note: CNAME is not supported at the zone apex - use Route 53 ALIAS or an ALIAS/ANAME record at your DNS provider for apex domains.

**RUNBOOK coverage:** Both `deploy/tofu/examples/aws/RUNBOOK.md` and `deploy/tofu/examples/stackit/RUNBOOK.md` include a "DNS Configuration" section describing both modes, manual registration steps for `external` mode, and import instructions for existing Stackit DNS zones.

**New variables (Story 13-10):**

| Variable | Example | Type | Default | Purpose |
|---|---|---|---|---|
| `dns_mode` | AWS + Stackit | string | `"external"` | DNS record creation mode; validated against `["default", "external"]` |
| `dex_subdomain_enabled` | Stackit only | bool | `false` | Create `dex.<server_name>` DNS record when `dns_mode = "default"` |
| `dns_contact_email` | Stackit only | string | `""` | Contact email for Stackit DNS zone (omitted when empty) |

### Stackit cloud-init Bootstrap (nebu-stackit - 13-3b, updated 13-8, 13-9)

`deploy/tofu/examples/stackit/cloud-init.tftpl` is rendered by `templatefile()` in `main.tf` and injected as `user_data` (base64-encoded) into the VM at provision time. On first boot, the VM:

1. Applies OS security patches (`package_upgrade: true`)
2. Installs Docker CE + Docker Compose plugin via the official Docker apt repository
3. Writes `/opt/nebu/` directory tree (permissions `0700`) with:
   - `.secrets/internal_secret` (mode `0600`, quoted scalar - no trailing newline)
   - `.env` (mode `0600`) - runtime secrets injected from OpenTofu variables (OIDC secrets, admin credentials, etc.). `NEBU_DB_URL`, `NEBU_DB_URL_MIGRATE`, and `NEBU_POSTGRES_SSL` are set directly in the `docker-compose.yml` `environment:` block — not in `.env` — so DB connection config is visible in compose without shell-variable expansion.
   - `/opt/nebu/dex/config.yaml` (mode `0600`, `oidc_mode = "dex"` only) - Dex static configuration
   - `docker-compose.yml` (mode `0640`) - two or three services: `server`, `gateway`, and conditionally `dex` (when `oidc_mode = "dex"`). No `postgres` service (managed PostgresFlex); no `keycloak` service.
4. Installs `/etc/systemd/system/nebu.service` - `Type=simple`, no `-d` flag; systemd owns the process lifecycle with `Restart=on-failure RestartSec=10`
5. Starts Docker (`systemctl start docker.service && sleep 2`) before starting `nebu.service`

**Changes in Story 13-9:**
- `keycloak` docker-compose service removed in both profiles - Keycloak is no longer deployed
- `KC_DB_PASSWORD` removed from `.env` - no Keycloak credentials
- Conditional Dex `write_files` entry and `dex:` service block added (guarded by `%{ if oidc_mode == "dex" ~}` template directive)
- `templatefile()` call no longer passes `kc_user`/`kc_password`; now passes `oidc_mode` and `dex_static_password_hash`
- `local.effective_oidc_issuer` computed in `main.tf` - auto-set to `http://<server_name>:5556/dex` for dex mode; uses `var.oidc_issuer` for external mode

**Changes in Media Gateway StackIT ObjectStore Story:**
- S3 credential `write_files` blocks added (guarded by `%{ if enable_media_gateway ~}` template directive)
  - `.secrets/s3_access_key` (mode `0600`)
  - `.secrets/s3_secret_key` (mode `0600`)
- Conditional `media:` service block added to `docker-compose.yml` with StackIT Object Store configuration
  - Image: `${NEBU_IMAGE_REGISTRY}/nebu-media:${NEBU_VERSION}`
  - Restart policy: `unless-stopped`
  - Depends on: `gateway` service (healthy)
  - Port binding: `127.0.0.1:8009:8009` (loopback only; gateway and nginx access via Docker network)
  - Health check: `wget -qO- http://localhost:8009/health` (10s interval, 5s timeout, 3 retries, 10s start grace)
  - Resource limits: CPU and memory configurable via `media_cpu_limit` and `media_memory_limit` variables
- `media` secrets block added to the secrets section (S3 credentials)
- nginx routing updated: conditionally adds `location /_matrix/media/` proxy blocks (both TLS and non-TLS modes)
  - Sets `client_max_body_size 50m` for large file uploads
  - Sets `Host`, `X-Real-IP`, `X-Forwarded-For` (overwritten with `$remote_addr`, story P5), `X-Forwarded-Proto` headers
- `templatefile()` call now passes `enable_media_gateway`, `s3_access_key`, `s3_secret_key`, `s3_endpoint`, `s3_bucket` variables

**Changes in Story 13-15:**
- Conditional `element` Docker service added (guarded by `%{ if enable_element_web ~}` template directive); see below for full details
- `/opt/nebu/element-config.json` write_files block added (conditional on `enable_element_web`)
- nginx routing updated: added `/api/v1/` → gateway and `location /` → Element blocks; WebSocket `Upgrade`/`Connection` headers added to the Element location

**Changes in Bug 5-30 (OIDC extra scopes configurable):**
- `NEBU_OIDC_EXTRA_SCOPES` env var added to `.env` in the cloud-init template with profile-conditional values:
  - `oidc_mode = "dex"`: `groups offline_access` (required for Dex group claims + refresh tokens)
  - `oidc_mode = "external"`: `""` (empty — external providers such as Keycloak may reject non-standard scopes)
- `docker-compose.yml` (local dev): `NEBU_OIDC_EXTRA_SCOPES=groups offline_access` added for the dev Dex environment
- The gateway reads `NEBU_OIDC_EXTRA_SCOPES` as the env-var fallback; a `server_config` / `bootstrap_draft` DB key `oidc_extra_scopes` takes unconditional precedence when present (see §8 Cross-Cutting Concepts — "Configurable OIDC Extra Scopes")

**Changes in Bug postgres-ssl-env-var (PostgreSQL SSL via separate env var):**
- `NEBU_POSTGRES_SSL: "true"` added to the `server:` service `environment:` block in `docker-compose.yml` (Stackit cloud-init template). Managed PostgreSQL services (Stackit PostgresFlex) require TLS; setting it here keeps the connection URL clean.
- `NEBU_DB_URL` and `NEBU_DB_URL_MIGRATE` moved from `.env` (shell-variable `$${…}` references) into the `environment:` block as literal values — no `${}` indirection needed anymore.
- `server/config/runtime.exs`: `Nebu.Repo` config gains `ssl: System.get_env("NEBU_POSTGRES_SSL", "false") == "true"`. URL query parameters `?ssl=true` / `?sslmode=require` are no longer used or needed.
- `server/lib/nebu/release.ex`: `postgres_ssl_opts/0` helper reads the same `NEBU_POSTGRES_SSL` env var and appends `[ssl: true|false]` to the Postgrex start opts used by the migration runner (`Nebu.Release.migrate/0`).

**Security invariants:**
- `pg_password` appears only inside `.env` (mode `0600`), never in plain environment variables or log output
- `dex_static_password_hash` is written only to `/opt/nebu/dex/config.yaml` (mode `0600`)
- ACL on PostgresFlex is set to `[var.network_cidr]` - never `0.0.0.0/0`
- `stackit_postgresflex_user.nebu.password` is stored in Terraform state - operators MUST use encrypted Stackit Object Storage backend (see `RUNBOOK.md`)
- `/opt/nebu/` is `0700` (root-only); `docker-compose.yml` is `0640`
- `nebu_version` variable rejects `"latest"` - a specific semver tag is required
- `oidc_client_secret` must not contain `"` or `\` characters (YAML interpolation constraint, enforced by variable validation)

Day-2 operations (updates, OIDC profile switching, backup, teardown) are documented in `deploy/tofu/examples/stackit/RUNBOOK.md`.

### Element Web Client (nebu-stackit - Story 13-15)

`deploy/tofu/examples/stackit/` supports an optional Element Web Matrix client deployment controlled by the `enable_element_web` variable. This allows end-users to access Nebu via a browser without installing a separate client.

**Variable:**

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `enable_element_web` | bool | `false` | Deploy `vectorim/element-web:v1.12.15` as a Docker Compose service and configure nginx routing |

**CORS constraint - `enable_tls = true` is required:**

When `enable_element_web = true` but `enable_tls = false`, Element Web runs on port 7070 and the gateway runs on port 8008 - different ports mean different origins. Browsers enforce the Same-Origin Policy: every Matrix API call from Element triggers a CORS preflight that fails because the gateway does not emit `Access-Control-Allow-Origin` for the Element origin. **All Matrix API calls from Element silently fail.**

When `enable_tls = true`, nginx terminates TLS and serves both services under a single origin (`https://<server_name>`), eliminating the CORS problem entirely.

A `lifecycle { precondition }` block in `deploy/tofu/examples/stackit/server.tf` enforces this constraint:

```hcl
condition     = !var.enable_element_web || var.enable_tls
error_message = "enable_element_web requires enable_tls = true ..."
```

`tofu apply` fails immediately if an operator sets `enable_element_web = true` with `enable_tls = false`.

**Docker service topology (when `enable_element_web = true`):**

```
vectorim/element-web:v1.12.15
  image:    vectorim/element-web:v1.12.15
  ports:    127.0.0.1:7070:80  (loopback only - nginx is the public entry point)
  volumes:  /opt/nebu/element-config.json:/app/config.json:ro
  depends_on: gateway (service_healthy)
  healthcheck: wget -qO- http://localhost/
```

Element binds to loopback only (`127.0.0.1:7070`) - it is never reachable directly from the internet. Port 7070 is intentionally absent from the Stackit security group rules. Only nginx (port 443) is the public entry point.

**nginx routing table (when `enable_tls = true` AND `enable_element_web = true`):**

| Path prefix | Proxied to | Purpose |
|---|---|---|
| `/_matrix/` | `http://127.0.0.1:8008` | Matrix Client-Server API |
| `/.well-known/matrix/` | `http://127.0.0.1:8008` | Matrix server discovery |
| `/oauth2/` | `http://127.0.0.1:8008` | OAuth authorization server (token, JWKS, authorize, revoke); story P5 |
| `= /account`, `/account/` | `http://127.0.0.1:8008` | Account page (exact match + prefix; `/accountx` stays with Element); story P5 |
| `= /.well-known/openid-configuration` | `http://127.0.0.1:8008` | OAuth discovery document; story P5 |
| `/admin/` | `http://127.0.0.1:8008` | Nebu Admin UI and API |
| `/api/v1/` | `http://127.0.0.1:8008` | Internal/compliance API |
| `/dex/` | `http://127.0.0.1:5556` | Dex IdP (only when `oidc_mode = "dex"`) |
| `/` | `http://127.0.0.1:7070` | Element Web client (catch-all) |

The `location /` block for Element is always listed last - nginx evaluates prefix locations in longest-match order, ensuring Matrix API paths are never accidentally routed to Element. (Table = `tls_mode = "acme"`, host nginx to the loopback-published `127.0.0.1:8008`; the `alb` compose proxy routes the same locations to `server:4000` on its `:8081` listener.)

The Element location includes WebSocket upgrade headers (`Upgrade`, `Connection`) to support future Matrix `/sync` long-polling and WebSocket transports.

**`element-config.json` - Security hardening:**

`/opt/nebu/element-config.json` is written by cloud-init at boot time with values interpolated from OpenTofu variables:

```json
{
  "m.homeserver": { "base_url": "https://<server_name>", "server_name": "<server_name>" },
  "brand": "Nebu",
  "disable_custom_urls": true,
  "disable_guests": true,
  "disable_3pid_login": true,
  "default_federate": false,
  "settingDefaults": {
    "UIFeature.registration": false,
    "UIFeature.passwordReset": false,
    "UIFeature.identityServer": false,
    "UIFeature.thirdPartyId": false
  },
  "sso_redirect_options": { "immediate": false }
}
```

`disable_custom_urls: true` prevents users from pointing Element at a different server. `UIFeature.registration` and `UIFeature.passwordReset` are disabled because Nebu uses OIDC-only authentication. The file is absent when `enable_element_web = false`.

**`element_url` output:**

`deploy/tofu/examples/stackit/outputs.tf` exposes an `element_url` output:

| Condition | Output |
|---|---|
| `enable_element_web = true` AND `enable_tls = true` | `https://<server_name>/` |
| `enable_element_web = true` AND `enable_tls = false` | `http://<server_name>:7070/` (blocked by precondition) |
| `enable_element_web = false` | `"disabled"` |

**`terraform.tfvars.example` documentation section:**

```hcl
# ── Element Web client ──────────────────────────────────────────────────────
# REQUIRES enable_tls = true - a lifecycle precondition blocks `tofu apply` if
# this constraint is violated. Without nginx (TLS), Element runs on port 7070
# while the gateway is on port 8008 - different origins cause CORS preflight
# failures for all Matrix API requests from Element.
#
# When enable_tls = true (required): nginx serves Element at / and proxies
# Matrix API paths (/_matrix/, /.well-known/matrix/, /admin/) to the gateway
# (port 8008). Element binds to 127.0.0.1:7070 (loopback only).
# enable_element_web = false
```

### Helm Chart

`deploy/helm/nebu/` is a standalone Helm Chart usable independently of OpenTofu.

**Kubernetes resource topology (Story 13-4a + 13-4b):**

| Resource | Name pattern | Conditional | Purpose |
|---|---|---|---|
| Deployment | `{release}-nebu-gateway` | always | Application pod (historical name; runs the single Elixir release); loads ConfigMap + optional Secret via `envFrom` |
| Deployment | `{release}-nebu-server` | always | Elixir/OTP server |
| Service (ClusterIP) | `{release}-nebu-gateway` | always | Port 8008 → gateway pods |
| Service (ClusterIP) | `{release}-nebu-server` | always | Port 9000 (gRPC) + 4000 (HTTP) → server pods |
| ConfigMap | `{release}-nebu-config` | always | `NEBU_OIDC_ISSUER`, `NEBU_SERVER_NAME`, `NEBU_CORE_GRPC_ADDR` (non-secret) |
| Ingress | `{release}-nebu` | `ingress.enabled: true` | nginx Ingress with configurable hostname and optional TLS secret |
| PersistentVolumeClaim | `{release}-nebu-postgres` | `postgres.external: false` | Postgres storage when running in-cluster |
| HorizontalPodAutoscaler | `{release}-nebu-gateway` | `autoscaling.gateway.enabled: true` | CPU-based HPA for gateway Deployment |

`NEBU_CORE_GRPC_ADDR` is derived deterministically from the release name as `{release}-nebu-server:9000` - rendered by the ConfigMap template, not a values entry.

> **ADR-022 note (OIDC is bootstrap-configured):** As of ADR-022 the application reads **no** OIDC config
> from the environment. The `NEBU_OIDC_*` / `NEBU_ADMIN_OIDC_*` values still rendered by the Helm chart and
> Tofu modules below are **ignored at runtime** — OIDC (issuer, audience, JWKS URI, the single client
> id/secret, claim mappings) is configured once via the **Bootstrap Wizard** (`server_config`). These IaC
> artifacts are pending a follow-up cleanup to drop the OIDC env entirely; operators should configure OIDC
> through the wizard, not via these env values.

**Secret management (ExistingSecret pattern):**

The chart never creates a Kubernetes Secret. Sensitive `NEBU_*` variables (`NEBU_DB_URL`, `NEBU_INTERNAL_SECRET`) must be stored in a pre-existing Kubernetes Secret, created out-of-band by the operator (OIDC is configured via the Bootstrap Wizard per ADR-022, not via a `NEBU_OIDC_CLIENT_SECRET` env):

```bash
kubectl create secret generic nebu-sensitive \
  --from-literal=NEBU_DB_URL='postgres://user:pass@host:5432/nebu' \
  --from-literal=NEBU_INTERNAL_SECRET='<64-char-random-hex>' \
  --from-literal=NEBU_OIDC_CLIENT_SECRET='<secret>'
```

The Secret name is referenced in `values.yaml` as `existingSecret.name`. When set, the gateway Deployment loads it via `envFrom.secretRef`. If the name is empty, no Secret is mounted and the gateway will fail to start - this is intentional (GitOps pre-deploy pattern) and documented in NOTES.txt.

Image tags must be set independently per component. Omitting either tag causes `helm install` to fail with an explicit error - preventing silent deployment of unversioned images.

```bash
# Minimal production install:
helm install nebu deploy/helm/nebu/ \
  --set gateway.image.tag=1.0.0 \
  --set server.image.tag=1.0.0 \
  --set config.oidcIssuer=https://your-idp.example.com \
  --set config.serverName=your-server-name \
  --set existingSecret.name=nebu-sensitive

# With Ingress + HPA:
helm install nebu deploy/helm/nebu/ \
  --set gateway.image.tag=1.0.0 \
  --set server.image.tag=1.0.0 \
  --set existingSecret.name=nebu-sensitive \
  --set ingress.enabled=true \
  --set ingress.hostname=nebu.example.com \
  --set ingress.tls.secretName=nebu-tls \
  --set autoscaling.gateway.enabled=true
```

### OpenTofu Kubernetes Wrapper (nebu-k8s - Story 13-4c)

`deploy/tofu/modules/nebu-k8s/` is a thin OpenTofu wrapper around a single `helm_release` resource. It manages the Nebu Helm release on any Kubernetes cluster. The Kubernetes and Helm providers must be configured in the calling root module.

**Module interface:**

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `release_name` | string | `"nebu"` | Helm release name |
| `chart_path` | string | required | Path to the Nebu Helm chart directory |
| `namespace` | string | `"nebu"` | Kubernetes namespace (created if absent) |
| `gateway_image_tag` | string | required | Container image tag for the gateway component |
| `server_image_tag` | string | required | Container image tag for the server component |
| `ingress_enabled` | bool | `false` | Enable the Ingress resource |
| `helm_timeout` | number | `300` | Seconds to wait for all pods to reach Ready state |
| `values_files` | list(string) | `[]` | Extra values files; must be non-empty absolute paths |

`wait = true` is set explicitly - `tofu apply` blocks until all pods are Ready or `helm_timeout` seconds elapse. This prevents silent partial deployments.

`values_files` paths must be absolute (use `"${path.module}/..."` in the calling root module) - relative paths are resolved from the `tofu apply` working directory, not the module directory.

**Quick-start example (`deploy/tofu/examples/k8s/`):**

```hcl
module "nebu_k8s" {
  source = "../../modules/nebu-k8s"

  chart_path        = var.chart_path
  namespace         = var.namespace
  gateway_image_tag = var.gateway_image_tag
  server_image_tag  = var.server_image_tag
  ingress_enabled   = var.ingress_enabled
  values_files      = ["${path.module}/../../../helm/nebu/values-dev.yaml"]
}
```

**Local smoke test (kind):**

```bash
# 1. Start a local kind cluster
kind create cluster --name nebu-dev

# 2. Validate IaC configuration (no cluster required)
make test-iac-validate

# 3. Install via Helm directly (fastest smoke test path)
helm install nebu deploy/helm/nebu/ \
  -f deploy/helm/nebu/values-dev.yaml \
  --set gateway.image.tag=dev \
  --set server.image.tag=dev

# 4. Wait for pods
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=nebu --timeout=180s -n default

# 5. Teardown
kind delete cluster --name nebu-dev
```

Full operator procedures (upgrade, rollback, HPA configuration, teardown) are in `deploy/tofu/examples/k8s/RUNBOOK.md`.

### UpCloud VM + Managed Services

`deploy/tofu/examples/upcloud/` provisions Nebu on UpCloud infrastructure with VMs, managed PostgreSQL, and Managed Object Storage (S3-compatible). The architecture mirrors Stackit: a single UpCloud VM runs Docker Compose with the Elixir application and optional media gateway, backed by a managed PostgreSQL database and S3-compatible object storage.

**Resources provisioned:**

- `upcloud_server` - Ubuntu 24.04 LTS VM; machine type configurable via `plan` variable (default: `2xCPU-2GB`)
- `upcloud_managed_postgresql_instance` - Managed PostgreSQL 16 database (single-server deployment; replicas optional)
- `upcloud_managed_object_storage` - Managed object storage (S3-compatible); provisioned with a bucket and long-lived access credentials
- `upcloud_loadbalancer` (story P5 state) - frontend `https-443` forwarding to the backend `matrix-api` (health check `GET /_matrix/client/versions`, HTTP 200): `tls_mode = "alb"` / `"dynamic"` = HTTP mode, TLS terminated at the LB, frontend rule `set_forwarded_headers`, member port `8081` (nginx proxy container); `acme` = TCP passthrough to VM port 443; `none` = TCP to VM port 8008. Frontend `http-80`: `alb` / `dynamic` = HTTP mode with a `http_redirect` (301) rule to https (member port 80 as default backend), `acme` = TCP passthrough to nginx `:80`
- DNS records (if `enable_dns = true`) - UpCloud DNS zone + A-record for the deployment

**Configuration Variables:**

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `enable_media_gateway` | bool | `false` | Deploy the media gateway with Managed Object Storage |
| `server_cpu_limit` | string | `"1.0"` | CPU limit for the server container |
| `server_memory_limit` | string | `"512m"` | Memory limit for the server container |
| `enable_tls` | bool | `true` | Enable ACME/Let's Encrypt TLS termination on the ALB |
| `enable_dns` | bool | `false` | Create DNS records via UpCloud DNS |

The server variable `NEBU_TRUSTED_PROXY_CIDRS` is set by the UpCloud template for `tls_mode` `acme` / `alb` / `dynamic` (gate m, story P5; derived from the pinned `compose_subnet`, optional realip via `lb_real_ip_cidrs`, see "Client IP behind a reverse proxy"); with `tls_mode = "none"` there is no proxy and all per-IP buckets are keyed on the LB peer.

### UpCloud Media Gateway Support

When `enable_media_gateway = true`, the UpCloud Terraform deployment creates an S3 bucket in Managed Object Storage and wires S3 credentials through the cloud-init template into the Elixir server's environment. The server processes media uploads and downloads against the S3-compatible endpoint using the same `Nebu.Media.StorageConfig` module that supports all platforms (AWS, STACKIT, UpCloud, local MinIO).

**Managed Object Storage Endpoints:**

UpCloud's `upcloud_managed_object_storage` resource exposes per-endpoint metadata including:

- `domain_name` - S3 API hostname and port (e.g. `7mf5k.upcloudobjects.com:443`)
- `iam_url` - IAM service endpoint for credential provisioning (e.g. `https://7mf5k.upcloudobjects.com:4443/iam`)
- `sts_url` - STS (Security Token Service) endpoint for AssumeRole-style token exchange (e.g. `https://7mf5k.upcloudobjects.com:4443/sts`)

**Configuration Variables (Media Gateway):**

| Variable | Type | Default | Purpose |
|---|---|---|---|
| `s3_access_key` | string (sensitive) | `""` | Access key for UpCloud Managed Object Storage (required when enabled) |
| `s3_secret_key` | string (sensitive) | `""` | Secret key for UpCloud Managed Object Storage (required when enabled) |
| `s3_endpoint` | string | Auto-derived | S3 endpoint `domain_name` extracted from `upcloud_managed_object_storage.endpoint` |
| `s3_iam_endpoint` | string | Auto-derived | IAM endpoint `iam_url` extracted from `upcloud_managed_object_storage.endpoint` |
| `s3_sts_endpoint` | string | Auto-derived | STS endpoint `sts_url` extracted from `upcloud_managed_object_storage.endpoint` |
| `s3_bucket` | string | `"nebu-media"` | S3 bucket name for media storage |

**Server Environment Variables (set via cloud-init when `enable_media_gateway = true`):**

```
NEBU_MINIO_ENDPOINT        — Extracted from UpCloud MOS domain_name (s3_endpoint)
NEBU_MINIO_IAM_ENDPOINT    — Extracted from UpCloud MOS iam_url (s3_iam_endpoint) — NEW in bugfix-upcloud-s3-iam-sts-endpoints
NEBU_MINIO_STS_ENDPOINT    — Extracted from UpCloud MOS sts_url (s3_sts_endpoint) — NEW in bugfix-upcloud-s3-iam-sts-endpoints
NEBU_MINIO_ACCESS_KEY_FILE — /run/secrets/s3_access_key (Docker Secret)
NEBU_MINIO_SECRET_KEY_FILE — /run/secrets/s3_secret_key (Docker Secret)
NEBU_MINIO_BUCKET          — From s3_bucket variable
NEBU_MINIO_USE_SSL         — "true" (UpCloud MOS requires TLS)
NEBU_STORAGE_ALLOW_PRIVATE_ENDPOINTS — default "false"; the UpCloud cloud-init sets it to "true". Set to "true" to allow the storage
                              endpoint and IAM/STS URLs to resolve to private addresses (RFC1918, CGNAT
                              100.64.0.0/10, IPv6 ULA) — required for UpCloud `*-private.upcloudobjects.com`
                              endpoints. Loopback/link-local/metadata stay blocked; preview_url and webhooks
                              are unaffected.
```

**`Nebu.Media.StorageConfig` Integration:**

- `iam_endpoint` / `sts_endpoint` fields (optional, `nil` by default) follow the
  same DB-override-with-env-fallback precedence as `endpoint`/`region`/
  `archive_bucket`: a saved `media_storage_config` DB value wins, else
  `NEBU_MINIO_IAM_ENDPOINT`/`NEBU_MINIO_STS_ENDPOINT` is used, else the
  compiled default (`nil`). This DB-override support (migration `000037`) was
  added by a follow-on bugfix (`bugfix-add-sts-iam-endpoints-to-admin-ui`) on
  top of the original env-only fields (`bugfix-upcloud-s3-iam-sts-endpoints`).
- Both are full URLs (e.g. `https://7mf5k.upcloudobjects.com:4443/iam`), not host:port pairs
- Neither field is a secret; both are stored and visible in the config table for operator inspection
- Admin-editable via `/admin/media/settings`, alongside the other storage-target
  fields. The save path applies a clear/no-op/override rule rather than plain
  blank-means-omit semantics: submitting the same value that is already in
  effect (whether DB- or env-sourced) is a no-op; blanking a field that
  currently has a genuine DB override clears that override back to
  env-controlled (writes `NULL`); a genuinely different, non-blank value
  persists as a new DB override. This prevents an untouched, env-pre-filled
  form field from silently freezing the env value into the DB on an unrelated
  save (e.g. saving just a credentials change would otherwise promote the
  pre-filled `iam_endpoint`/`sts_endpoint` into a permanent DB row).
- Both fields are validated as full `https://` URLs checked against
  `Nebu.Media.SSRF.checked_target/1` (rejecting private/loopback/link-local/
  cloud-metadata addresses) before being persisted — added by this bugfix's
  security review, since these fields are now admin-UI-writable and
  DB-persisted rather than env-only/no-write-path.

Note: The `iam_endpoint` and `sts_endpoint` fields are plumbed through as configuration but are not yet actively consumed by the ExAws S3 client (runtime STS AssumeRole exchange). They are available for future integration when a live UpCloud account confirms a runtime STS flow is required. The bugfix ensures the three URLs (endpoint, iam_url, sts_url) exposed by UpCloud's Managed Object Storage resource are threaded end-to-end into the application's config module, enabling future use cases without further IaC changes.

**Local IaC Validation:**

UpCloud examples are included in the `make test-iac-validate` target, validating all Terraform configurations (AWS, STACKIT, UpCloud, Kubernetes) together with no cloud credentials required.

---

## Load Test Topology (Story 13-5)

`docker-compose.scale.yml` is a Compose override that removes the fixed host-port binding from the gateway service so Docker Compose can start multiple replicas without port conflicts.

### Multi-Gateway Scale-Up

```bash
# Start full stack with 2 gateway replicas
docker compose -f docker-compose.yml -f docker-compose.scale.yml up \
  --scale gateway=2 --build -d --wait
```

Both replicas connect to the same Server instance via `server:9000` (gRPC) and share the `internal_secret` PSK. For 2-server clustering, see Story 13-6 below.

```
k6 load generator
  │ HTTP  (nebu_default Docker network)
  ▼
[gateway replica 1] ──gRPC:9000──▶ server
[gateway replica 2] ──gRPC:9000──▶ server
                                     │
                                     ▼
                               PostgreSQL 16
```

---

## Server Clustering (Story 13-6): libcluster + Horde Failover

The Elixir Server supports horizontal scaling via libcluster for node discovery and Horde for distributed Room GenServer supervision. When a Server node fails, Horde automatically restarts Room GenServers on the surviving node within seconds (no manual intervention).

### Architecture

```
[gateway] ──gRPC:9000──▶ [server (nebu@server)]   ←── Horde CRDT cluster ───▶ [server2 (nebu@server2)]
                               │                                                    │
                          Room GenServers                                   Room GenServers
                           (Horde Registry)                               (Horde Registry)
                               │                                                    │
                               └───────────────┬──────────────────────────────────┘
                                               ▼
                                        PostgreSQL 16
```

When `server` (nebu@server) is stopped:
1. Horde CRDT reconciliation detects the node departure
2. Room GenServers that were running on `server` are restarted on `server2`
3. Horde Registry re-registers the rooms under `server2`'s node
4. Gateway's next gRPC call succeeds (Room GenServer is alive on `server2`)

### Clustering Strategies

| Environment | Strategy | Discovery |
|---|---|---|
| Docker Compose | `Cluster.Strategy.Gossip` | UDP broadcast (port 45892) within Docker network |
| Kubernetes | `Cluster.Strategy.Kubernetes.DNS` | Headless Service DNS lookup (`server-headless`) |

### Environment Variables

| Variable | Purpose | Example |
|---|---|---|
| `CLUSTER_STRATEGY` | Selects libcluster strategy (`gossip` / `kubernetes`) | `gossip` |
| `RELEASE_NODE` | Erlang node name for distribution | `nebu@server` |
| `RELEASE_DISTRIBUTION` | Erlang distribution mode (`name` = long names) | `name` |
| `CLUSTER_NODES` | Comma-separated peer list (informational; Gossip discovers dynamically) | `nebu@server` |

### Local 2-Server Stack

```bash
# Start full stack with 2 Server nodes + scaled gateways
docker compose -f docker-compose.yml -f docker-compose.scale.yml up -d

# Simulate node failure (AC1 test)
docker stop $(docker compose -f docker-compose.yml -f docker-compose.scale.yml ps --format json | jq -r 'select(.Service=="server") | .Name')

# Verify room availability after failover (rooms migrate to server2 within 10 seconds)
```

The `docker-compose.scale.yml` override adds:
- `server` service: sets `RELEASE_NODE=nebu@server` and `CLUSTER_STRATEGY=gossip`
- `server2` service: same image, `RELEASE_NODE=nebu@server2`, connects to server1 via Gossip multicast

### Kubernetes Clustering

When `server.replicaCount > 1` in `values.yaml`, the Helm chart automatically injects:
- `CLUSTER_STRATEGY=kubernetes` → activates `Cluster.Strategy.Kubernetes.DNS`
- `RELEASE_NODE=nebu@$(MY_POD_IP)` → unique long-form node name per pod
- `RELEASE_DISTRIBUTION=name` → enables Erlang long-name distribution
- `KUBERNETES_SERVICE_NAME` pointing to the headless Service (`server-headless`)

A headless Service (`server-deployment-headless`) is automatically provisioned alongside the standard ClusterIP Service when `replicaCount > 1`. The headless Service returns A records for each pod, enabling libcluster to discover peers via DNS.

### Health Endpoint - Cluster Status

`GET http://server:4000/health` now includes `cluster_nodes` in its JSON response:

```json
{
  "status": "UP",
  "node": "nebu@server",
  "cluster_nodes": ["nebu@server2"],
  "components": { ... }
}
```

`cluster_nodes` is an empty list in single-node mode (no libcluster configured).

### Erlang Cookie (Security)

Erlang distribution requires all nodes in a cluster to share the same cookie. In production deployments:
- **Docker Compose:** uses Erlang's default auto-generated cookie (acceptable for dev; nodes on the same Docker network)
- **Kubernetes/AWS:** `RELEASE_COOKIE` is injected from Secrets Manager (see AWS secrets.tf) to ensure all Server pods use the same pre-shared cookie
- **STACKIT:** operators must set a consistent `RELEASE_COOKIE` in the cloud-init bootstrap across all Server VMs

### k6 Scenario Files

| File | Tier | VUs | Duration | Send p95 threshold |
|---|---|---|---|---|
| `k6/scenarios/gold-tier.js` | Gold | 1000 | 5 min | < 500 ms |
| `k6/scenarios/silver-tier.js` | Silver | 500 | 5 min | < 800 ms |

Each scenario exercises three endpoints per VU per iteration: `POST /_matrix/client/v3/login`, `GET /_matrix/client/v3/sync`, `PUT /_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}`.

Custom metrics reported: `nebu_login_duration`, `nebu_sync_duration`, `nebu_send_duration` (each as a Trend with p50/p95/p99), plus per-endpoint error rates. See `k6/README.md` for full operator instructions.

### CI Syntax Gate

```bash
make test-load-syntax   # k6 inspect (both scenarios) + docker compose config --quiet
```

This gate runs as part of `make test-iac-validate` (no running stack required).

---

## Release Pipeline (Story 13-11)

Story 13-11 introduces a versioned release track that runs alongside the existing SHA-tagged build track. The two tracks are intentionally separate and do not interfere with each other.

### Two-Track Image Strategy

| Track | Trigger | Image tag pattern | Purpose |
|---|---|---|---|
| Build (existing) | Every push / MR | `gateway:<SHA>`, `server:<SHA>` | Feeds integration tests; ephemeral |
| Release (new) | SemVer Git tag (`v*.*.* `) | `nebu-gateway:<semver>`, `nebu-server:<semver>` | Production images; referenced by operators |

**Image naming:** Release images use the `nebu-gateway` / `nebu-server` prefix (not `gateway` / `server` as in build images). This distinguishes them at the registry level and prevents accidental cross-track references.

**Version stripping convention:** Git tag `v1.0.0` → image tag `1.0.0` (the `v` prefix is stripped in both the CI pipeline and the `make release` target).

### CI Release Stage

Two Kaniko jobs in the new `release` stage of `.gitlab-ci.yml`:

```yaml
release-gateway-image:   # → <CI_REGISTRY_IMAGE>/nebu-gateway:<semver>
release-server-image:    # → <CI_REGISTRY_IMAGE>/nebu-server:<semver>
```

Both jobs:
- Are gated by `if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'` - stable SemVer only; RC/beta tags (`v1.0.0-rc1`) are excluded
- Set `interruptible: false` and `needs: []` - run independently of branch-only build/integration jobs
- Use `--cache=false` - no reuse of branch-build Kaniko cache layers, ensuring deterministic and reproducible production images
- Pass `GIT_COMMIT`, `BUILD_TIME`, and `RELEASE_VERSION` as `--build-arg` to the Dockerfile

The `workflow:` block in `.gitlab-ci.yml` has been extended to allow tag pipelines:

```yaml
workflow:
  rules:
    - if: '$CI_COMMIT_TAG =~ /^v\d+\.\d+\.\d+$/'   # NEW: SemVer tag pipelines
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    ...
```

### Makefile Release Targets

```makefile
make release TAG=v1.0.0       # Build gateway + server release images locally
make release-push TAG=v1.0.0  # Push to registry (requires docker login)

# Full release workflow:
TAG=v1.0.0 make release release-push
```

`make release` validates that `TAG` matches `vN.N.N` before building. `CI_REGISTRY_IMAGE` defaults to `registry.gitlab.com/philippb/open-chat` and can be overridden for forks.

### Operator Integration

Operators reference release images via the `nebu_version` variable in OpenTofu or image tags in Helm:

**OpenTofu (all three platforms):**
```hcl
nebu_version   = "1.0.0"   # strips 'v' prefix; matches image tag
image_registry = "registry.gitlab.com/myorg/open-chat"
# → pulls: <image_registry>/nebu-gateway:1.0.0 and nebu-server:1.0.0
```

**Helm:**
```bash
helm install nebu deploy/helm/nebu/ \
  --set gateway.image.tag=1.0.0 \
  --set server.image.tag=1.0.0 \
  --set image.registry=registry.gitlab.com/myorg/open-chat \
  --set existingSecret.name=nebu-sensitive
```

The `nebu_version` variable in the `nebu-shared` shared module already enforces a semver regex and rejects `"latest"` - this constraint remains in force for all release images.

_Source: Story 13-11 staged changes - `.gitlab-ci.yml`, `Makefile`, `deploy/helm/nebu/values.yaml`, `deploy/tofu/examples/*/terraform.tfvars.example`; Story 13-14 (squashed seed migration - single `000001_init.up.sql`, `make dev-reset-db` target, Stackit `nebu_migrate`/`nebu_legacy` backward-compat users)_
