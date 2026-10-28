# 9 Architecture Decisions

This section is an index of all Architecture Decision Records (ADRs) for Nebu.
Individual ADR files live in [`docs/architecture/adr/`](adr/).

## ADR Index

| ADR | Title | Status | Date |
|---|---|---|---|
| [ADR-001](adr/ADR-001-elixir-otp.md) | Elixir/OTP as Core Runtime | Accepted | 2026-03-18 |
| [ADR-002](adr/ADR-002-no-redis-nats.md) | No Redis, No NATS - ETS + pg Process Groups | Accepted | 2026-03-18 |
| [ADR-003](adr/ADR-003-content-hash-event-id.md) | Content-Hash Event IDs (Matrix Room Version 6+) | Accepted | 2026-03-18 |
| [ADR-004](adr/ADR-004-horde-registry.md) | Horde Registry + DynamicSupervisor for Room GenServers | Accepted | 2026-03-18 |
| [ADR-005](adr/ADR-005-grpc-eventbus.md) | gRPC Server-Streaming EventBus + Unary Fallback | Superseded by ADR-021 | 2026-03-18 |
| [ADR-006](adr/ADR-006-message-buffer-drain.md) | message_buffer Drain Strategy (Linear MVP, AIMD Phase 2) | Accepted | 2026-03-18 |
| [ADR-007](adr/ADR-007-ed25519-x25519-keypairs.md) | Ed25519 (Signing) + X25519 (Encryption) - Two Key Pairs per User | Accepted | 2026-03-18 |
| [ADR-008](adr/ADR-008-node-registration-psk.md) | Node Registration: PSK via Compose Secrets (MVP) → Ephemeral mTLS (Phase 2) | Accepted | 2026-03-18 |
| [ADR-009](adr/ADR-009-openapi-spec-first.md) | OpenAPI Spec-First with oapi-codegen | Accepted | 2026-03-18 |
| [ADR-010](adr/ADR-010-fts-strategy.md) | Full-Text Search Strategy | Accepted | 2026-05-08 |
| [ADR-011](adr/ADR-011-managed-e2ee-key-escrow.md) | Managed E2EE Key Escrow | Proposed | - |
| [ADR-012](adr/ADR-012-upstream-repo-no-deployments-example-credentials.md) | Upstream Repo Contains Example-Only Credentials - No Official Deployments | Accepted | 2026-05-04 |
| [ADR-013](adr/ADR-013-minio-object-storage.md) | MinIO as S3-Compatible Object Store for MVP | Accepted | 2026-05-12 |
| [ADR-014](adr/ADR-014-deployment-strategy-iac.md) | Deployment Strategy and Infrastructure-as-Code | Accepted | - |
| [ADR-015](adr/ADR-015-oidc-user-directory-integration.md) | OIDC User Directory Integration Strategy (Protocol A + B) | Accepted | 2026-05-16 |
| [ADR-016](adr/ADR-016-git-branching-release-strategy.md) | Git Branching and Release Strategy | Superseded by ADR-017 | 2026-05-04 |
| [ADR-017](adr/ADR-017-simplified-main-only-branching.md) | Simplified Main-Only Branching | Accepted | 2026-05-04 |
| [ADR-018](adr/ADR-018-no-domain-model-locality-of-behavior.md) | No Domain Model — Locality of Behavior as Architectural Principle | Accepted | 2026-06-17 |
| ADR-019 | Single Mix application (no umbrella) — `:nebu`, one `Nebu.Application` supervisor tree | Accepted | 2026-06-17 |
| ADR-020 | Feature domains as module namespaces (`Nebu.Matrix`/`Media`/`Admin`/`Web`/`Compliance`) within the one app | Accepted | 2026-06-17 |
| ADR-021 | Remove Go entirely — the Elixir/OTP application is the whole system; no gateway↔core process boundary | Accepted | 2026-06-17 |
| ADR-005 (superseded) | gRPC fully removed (`grpc-removal` epic): `:grpc`/`:protobuf` deps gone, `Core.*` are plain `defstruct` DTOs, `Nebu.Matrix.Error`/`Status` replace `GRPC.RPCError`/`GRPC.Status` | Superseded | 2026-06-22 |
| [ADR-022](adr/ADR-022-oidc-bootstrap-only-configuration.md) | OIDC configured EXCLUSIVELY via the Bootstrap Wizard (`server_config`, read through `Nebu.Web.OidcConfig`); all `NEBU_OIDC_*`/`NEBU_ADMIN_OIDC_*` env config removed; a SINGLE OIDC client serves both Matrix Bearer validation and admin login; fail-closed until bootstrapped | Accepted | 2026-06-28 |
| [ADR-033](adr/ADR-033-authorization-server-broker-model.md) | Nebu is the OAuth 2.0 Authorization Server (broker model O2) in front of the corporate IdP: only Nebu issues Matrix tokens, scopes are Nebu-internal (the IdP sees one client), open Dynamic Client Registration with mandatory admin approval (no auto-approve; pending rows capped + TTL-purged, approved/rejected never deleted; client logos only loaded on click under a strict CSP), https-for-all-URLs (stricter than RFC 6749), `oauth_enabled` default off (404 `M_UNRECOGNIZED`); legacy IdP-JWT path coexists temporarily; story 2 (2026-10-10) adds D1-D23 for `/oauth2/authorize`: the IdP leg reuses the ONE shared, already registered IdP callback (state tag `o2.`, no `/oauth2/callback`), flow state + PKCE verifier in the database (`oauth_authz_requests`, not node-local), per-flow browser-binding cookie, hash-only single-use authorization codes (`oauth_codes`, 60 s, reuse detection), no consent screen (admin approval is the gate; IdP gets `prompt=login` + `max_age=0`), `iss` on every response (RFC 9207), story 3 (oauth-token-endpoint, 2026-10-10) adds T1-T33 for `POST /oauth2/token`, `GET /oauth2/jwks` and `GET /.well-known/openid-configuration`: OAuth sessions are `matrix_sessions` rows with `auth_api='oauth'` (migration 000042; two expiries, hash-only opaque tokens, device reuse deletes earlier rows, legacy rows untouched), refresh rotation with PENDING/CONSUMED reuse detection and per-refresh IdP re-validation (fail closed), proof-gated code-reuse revocation (deliberate deviation from the RFC 6749 SHOULD), Nebu-generated ES256 signing keys (SecretBox at rest, lazy single-winner generation, JWKS), id_token with `openid`, every 5xx answered `{}` + `Retry-After` so oidc-client-ts does not log clients out, CORS `*` without credentials on token/JWKS/openid-configuration, kill-switch 404 without an `error` member, no raw IdP JWT for OAuth devices, story 4 (oauth-token-revocation-logout, 2026-10-10) adds R1-R24 for `POST /oauth2/revoke` (RFC 7009), OAuth-aware `POST /logout`, the newly routed `POST /logout/all` and the GDPR erasure session kill: a revocation ends the whole device session (all `matrix_sessions` rows + device + keys) in ONE locked transaction (devices row `FOR UPDATE`, order devices -> matrix_sessions), either token in any state, no client authentication (Matrix spec precedence over the RFC 7009 client binding) and no oracle (byte-identical `200 {}` with `application/json` for revoked/unknown/malformed/legacy tokens), live even while `oauth_enabled=false` (exempt from the T22 kill switch, only `:unknown` => 503 `{}`), credentials-free CORS, bucket `{"oauth_revoke", ip}` 60/min, `POST /logout/all` all-or-500 over the union of devices and sessions with a durable caller-JWT denylist, legacy `POST /logout` unchanged as a recorded spec deviation (gate item r); every advertised endpoint now exists, story 5 (oauth-legacy-coexistence, 2026-10-10) adds C1-C20 for parallel operation of the legacy and the OAuth API: `auth_api` on every session is the source of truth (a session only uses the API that issued it), one liveness predicate (`Nebu.OAuth.Config.live_state/0`, facade `oauth_aware?/0`) gates the `GET /login` flags `oauth_aware_preferred` / `org.matrix.msc3824.delegated_oidc_compatibility` (on `m.login.sso` only, fail closed, `GET /login` always 200) and the SSO `action` (`login`/`register`, `register` => `prompt=create` as a Nebu extension, value never logged), OAuth callers get `403 M_FORBIDDEN` at `DELETE /devices` and `POST /delete_devices` (the UIA API is not usable with OAuth; the account page is story 6), UIA freshness is legacy-only, every non-preserved device deletion (legacy, admin) uses the atomic locked `Nebu.Matrix.end_device_session/2`, the JWT kill-switch `DeviceBinding.kill_device_jwts/3` is fail closed (`TokenDenylist.revoke_by_hash/2 :: :ok | {:error, term}`, refusal semantics in `DeviceBinding`, a raw JWT never writes keys of an OAuth device, denylisted JWT login refused), account endpoints stay unrouted, the raw-JWT path and device take-over stay as documented residuals, and the deprecation path (`legacy_login_enabled` / `oauth_enabled=false`) is documented, not implemented, story 6 (oauth-account-management, 2026-10-12) adds A1-A27 for the account-management page and the `m.oauth` UIA stage: `GET /account` (+ `/account/reauth`, device delete, reset approve / decline, logout; no CORS) lives under exactly the `auth_metadata` predicate and is advertised as `account_management_uri` / `account_management_actions_supported` (five actions, Element's `device_view` sign-out entry, input aliases, default page for unknown actions); sign-in through the ONE shared IdP callback with its own state tag `o2.acct.` (database-backed flow state, `max_age=0`, `auth_time` freshness, no provisioning, legacy-only users served); DB-backed hashed browser session (`__Host-nebu_account`, idle 900 s / absolute 3600 s, rotation, NOT a Matrix device); CSRF by an HMAC-derived token + Origin / Sec-Fetch checks, `Referrer-Policy: same-origin`; destructive actions need a fresh IdP re-auth (300 s); device deletion through the locked `end_device_session/2` (gate item w closed); `POST /keys/device_signing/upload` answers OAuth replacements with the `m.oauth` 401 challenge whose approval (`uia_sessions` op `cross_signing_reset`) is single use and bound to user, device and the SHA-256 of all supplied keys, consumed in one transaction with the key write (legacy callers keep `403`; the "unchanged" rule now compares supplied keys only); DELIBERATE DEVIATION A17: an account re-auth never refreshes `matrix_sessions.auth_time`; standalone strict-CSP renderer, no audit rows, purge via `OAuthFlowPurgeWorker`, migration 000043 (RLS, grants); `oauth_enabled` stays off (gate items 1, h, i, l, m (now incl. `/account*`), n, r, y, ag and story 9); legacy SSO redirect confirmation (story legacy-sso-redirect-confirmation, SEC gate 3 G3-3, 2026-10-13): an https legacy `redirectUrl` that is not listed (`https://<server_name>`, the issuer origin, registered redirect URIs of approved clients, the Admin list `sso_redirect_allowed_origins`) gets a confirmation page after the IdP login and before any `loginToken`; no COOP on that flow (popup clients) | Accepted | 2026-10-09 |

## Decision Drivers

All ADRs 001–009 were finalized during the architecture phase (2026-03-18) after evaluation of
alternatives. The key drivers were:

1. **Minimize operational complexity** - fewer moving parts means fewer failure modes
2. **Matrix protocol compatibility** - design choices must not create incompatibilities
3. **GDPR compliance** - cryptographic deletion requires a specific key architecture
4. **Horizontal scalability from day one** - Horde and stateless gateway design decisions front-loaded
5. **Apache 2.0 ecosystem** - all dependency choices verified against license compatibility

ADR-010 (FTS strategy) was accepted on 2026-05-08: PostgreSQL native `tsvector`/`tsquery` with
a GIN index on the `events` table (migration 000042, Story 11-1). No external search service
is introduced. See [`ADR-010`](adr/ADR-010-fts-strategy.md) for the full rationale.

ADR-011 (Managed E2EE) is pending because it requires additional investigation and community
input before the design can be finalized.

ADR-018 (No Domain Model) was accepted on 2026-06-17: Nebu uses no ORM, no Repository pattern,
and no Domain Model. SQL is written inline in the endpoint implementation file. The primary driver
is *Locality of Behavior* — a deliberate adaptation for LLM-assisted development (BMAD methodology)
where keeping all relevant code in one file reduces context-graph depth and hallucination risk.
See [`ADR-018`](adr/ADR-018-no-domain-model-locality-of-behavior.md) for the full rationale.

## Single Elixir Application — Go Removed (ADR-019 / ADR-020 / ADR-021)

The `full-elixir-stack` / `otp-consolidation` / `grpc-removal` work removed all non-Elixir components.
Nebu is one Mix application (`:nebu`, a single `Nebu.Application` supervisor tree — **not** an umbrella,
ADR-019) whose feature domains are module namespaces (`Nebu.Matrix`, `Nebu.Media`, `Nebu.Admin`,
`Nebu.Web`, `Nebu.Compliance` — ADR-020). The stateless Go gateway and Go media gateway are deleted
(ADR-021); the HTTP surface (Matrix C-S API, media, Admin UI) and all stateful chat logic run in the
same BEAM node and call each other **in-process**. The gRPC gateway↔core boundary that ADR-005
originally defined no longer exists and gRPC is fully removed (ADR-005 superseded, 2026-06-22):
`Core.*` are plain `defstruct` DTOs, `Nebu.Matrix.EventDispatcher.Server` is a plain Elixir module,
and errors use `Nebu.Matrix.Error` / `Nebu.Matrix.Status`. Migrations are raw SQL applied by
`Nebu.Release.migrate/0` (ADR-018), not golang-migrate.

## All-Elixir Media Path (media-gateway-migration → ADR-021)

The media path is `Nebu.Media.*`, serving the Matrix media endpoints in-process behind the OIDC plug;
the standalone Go `media` service is gone. This realizes three existing decisions in the Elixir stack
rather than introducing a new ADR:

- **[ADR-011](adr/ADR-011-managed-e2ee-key-escrow.md) (Managed E2EE Key Escrow):** media objects are
  AES-256-GCM encrypted at rest with the per-object AES key + nonce stored (hex) in `media_files` — the
  server-side key-escrow model.
- **[ADR-013](adr/ADR-013-minio-object-storage.md) (MinIO S3-Compatible Object Store):** object storage
  uses `ExAws.S3` against MinIO; the server service reads the MinIO credentials from file-based Docker
  secrets.
- **[ADR-018](adr/ADR-018-no-domain-model-locality-of-behavior.md) (No Domain Model):** the media code
  uses inline SQL with no schema/repository; boundary seams are injected via `Application.get_env`.

A consequential design change: media access control is now a local `room_members` SQL call inside the
application, replacing the former gRPC `CheckMembership` RPC (one fewer cross-process hop). See §5
Building Blocks and §8 Cross-Cutting Concepts for the component and concept detail.

## Phoenix Admin UI — HTTP Controllers + LiveView (admin-ui-migration + admin-http-refactor → ADR-020/021)

The Admin UI is `Nebu.Admin.*` — hosted in the single application (the Go-template admin that used
to compile into the gateway binary is deleted). This realizes two existing decisions rather than
introducing a new ADR:

- **[ADR-001](adr/ADR-001-elixir-otp.md) (Elixir/OTP as Core Runtime):** the admin UI runs on the BEAM
  within the one application — consistent with placing all stateful and server-rendered logic in
  Elixir/OTP rather than in Go.
- **[ADR-018](adr/ADR-018-no-domain-model-locality-of-behavior.md) (No Domain Model):** all admin
  controllers and LiveViews use inline SQL directly in the module — no repository layer, no domain
  model. Consistent with the ADR-018 locality-of-behavior principle.

**admin-http-refactor:** CRUD admin pages (Users, Rooms, Spaces, Config, ClaimMapping, RoleMapping,
Compliance) were refactored from Phoenix LiveViews to native Phoenix HTTP controllers following the
Post-Redirect-Get (PRG) pattern. Each controller has a corresponding HTML view module and HEEx
template. Three LiveViews remain: DashboardLive, AuditLogLive, and BootstrapLive — pages that
benefit from real-time server-push or multi-step stateful flows. The admin router was updated
accordingly: `live/3` routes replaced with `get`/`post`/`delete` for the converted pages. A new
`require_admin` plug was added to `Nebu.Admin.Auth` for the HTTP controller pipeline (complementing
the existing `on_mount :require_admin` for LiveViews).

**Admin login owned in Elixir (ADR-021):** `Nebu.Admin.Auth` owns the complete admin OIDC
Authorization-Code + PKCE login. `/admin/login/start` generates the PKCE verifier/S256 challenge + CSRF
state + OIDC nonce (stashed in the signed Phoenix session) and 302-redirects to the IdP;
`/admin/callback` validates state (constant-time, fail-closed), exchanges the code at the provider
token endpoint with the PKCE verifier, verifies the ID token via the shared OIDC-plug verify (alg
allowlist, JWKS signature, fail-closed iss/aud, exp, sub) plus the nonce binding, enforces the
admin-group claim, and mints the Phoenix admin session (`renew: true`, `session_exp = min(idToken.exp,
now+8h)`). `/admin/logout` clears it. The admin OAuth client is configured via
`NEBU_ADMIN_OIDC_CLIENT_ID` / `..._CLIENT_SECRET[_FILE]` / `..._REDIRECT_URI` (a fixed,
server-controlled redirect target — never derived from request headers).

**Admin silent OIDC refresh (Story admin-oidc-session-refresh):** when refresh is active,
`Nebu.Admin.Auth.fetch_current_user/2` checks `session_exp` on every authenticated HTTP request: within
a 120 s pre-expiry window it silently exchanges the stored OIDC `refresh_token` (encrypted with
`Nebu.Web.SecretBox` AES-256-GCM inside the signed admin session cookie — no DB row) at the provider
token endpoint, re-verifies the new `id_token` via `OidcPlug.verify_token`, **re-evaluates the
admin-group gate on the refreshed claims**, recomputes `session_exp = min(new id_token.exp, now+8h)`,
renews the session (`renew: true`) and rotates the stored RT. Refresh failure or a lost admin group
clears the session and redirects to `/admin/login`. This removes the prior "capped at the short
`id_token.exp` with no refresh" behaviour that forced an admin re-login roughly every 5 minutes against
Keycloak. **Known limitation:** refresh happens on HTTP round-trips, not over the live LiveView
websocket.

**Configurable OIDC refresh mode (Story oidc-refresh-mode-config):** whether each client requests an
OIDC refresh token is now **operator-configurable per client**, not hardcoded. Two `server_config` keys
— `matrix_oidc_refresh_mode` and `admin_oidc_refresh_mode`, each `offline | online` — control it.
Defaults: **Matrix = `offline`, Admin = `online`**. The mode is set at bootstrap and is changeable at
runtime via `/admin/config` (applies to subsequent logins, no redeploy). The scope builders read the
mode **live**: `Nebu.Matrix.SsoLogin.scope_list/0` and `Nebu.Admin.Auth.admin_oidc_scope/0` append
`offline_access` **iff** the client's mode is `offline`; `openid` is always mandatory. Consequently the
admin client **no longer force-requests `offline_access`** (its `online` default needs no special IdP
approval). IdP caveat: **Dex** issues a refresh token only when `offline_access` is requested, so admin
`online` mode disables silent refresh on Dex; **Keycloak** supports session-bound online refresh.

**Configurable OIDC extra scopes (Story configurable-oidc-scopes):** which scopes Nebu requests
beyond `openid` is now **operator-configurable per client** via Bootstrap Wizard and `/admin/config`.
Two `server_config` keys — `matrix_oidc_extra_scopes` and `admin_oidc_extra_scopes` — control it.
Both default to `""` (empty): when no row exists, the scope is `openid` only (OIDC Scopes Law,
bugfix-remove-default-scopes). `openid` is always injected by the scope builders and cannot be
removed. Scope tokens are whitelist-validated (`[a-zA-Z0-9_:.-]+`, `\z`-anchored) at all three
write boundaries: wizard save, config-page POST, and bootstrap promotion. Migration `000013`
extends the `config_update_mutable` RLS policy. This replaces the former `NEBU_OIDC_EXTRA_SCOPES`
env approach (removed by ADR-022).

## Matrix Session Storage Pattern (Story oidc-session-refresh)

Matrix user sessions are now stored server-side in the `matrix_sessions` table, following the same
pattern as admin sessions. This concept is realised in the Elixir/OTP stack (ADR-021); the Go gateway
that earlier revisions referenced is gone. The implementation is `Nebu.Matrix.Session.MatrixSessionStore`
(inline SQL over `matrix_sessions`, ADR-018), with token-shape dispatch in `Nebu.Web.Plugs.OidcPlug`
(opaque = no `.`) and at-rest encryption of the OIDC refresh token via `Nebu.Web.SecretBox` (AES-256-GCM).

Opaque access + refresh tokens (Matrix CS API v1.3, `POST /_matrix/client/v3/refresh`) are decoupled
from the OIDC provider's token lifetime: the Nebu session expires at `min(oidc_exp, now + 8h)`, so a
Matrix client keeps a working session even when the OIDC `id_token` expires in minutes (Keycloak
default: 5 minutes) — this fixes the "force-logout every 5 min" regression.

The dual model is backward compatible: `POST /login` only mints opaque tokens when the client sends
`refresh_token: true`; otherwise the raw OIDC JWT is still returned as `access_token`. Logout and admin
`deactivate_user` both delete the user's `matrix_sessions` rows. The key architectural decision: Matrix
session lifetime is controlled by Nebu, not by the upstream OIDC provider. Proactive OIDC RT refresh is
deferred to Phase 2.

## Known Gaps & Follow-Ups

**Sync state events missing identity — Fixed (bugfix: sync-state-events-missing-fields):**
State events in `/sync` now include real `event_id`, `origin_server_ts`, `unsigned` fields per the
Matrix spec. Follow-ups remain:
- `/initialSync` and `/rooms/{roomId}/members`: **resolved by story membership-state-model (2026-10-20)**: both serve the member
  events with their real event ids, `origin_server_ts` and `unsigned` through `Nebu.Matrix.Http.state_event_json/3`; a
  synthesized id (`$synth_`, request time) remains only for a legacy member without any member event.
- `rooms.invite` and `rooms.leave` sections of `/sync` currently omit all state events entirely
  (hardcoded `{}` in `sync_response/2`). This is a separate, larger gap (documented in
  `Nebu.Matrix.Http` moduledoc as MINOR-2) and is **not** part of the state-events-missing-fields scope.

_Source: `CLAUDE.md`, §Resolved Architecture Decisions; `_bmad-output/planning-artifacts/architecture.md`, §Core Architectural Decisions_
