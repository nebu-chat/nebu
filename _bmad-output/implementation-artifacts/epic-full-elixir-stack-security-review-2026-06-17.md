# Epic full-elixir-stack Security Review (SEC Gate 2) — 2026-06-17

Reviewer: Kassandra (adversarial security review, epic-end mandatory gate)

## Scope

- **Epic:** `full-elixir-stack` (Go gateway + media gateway fully removed; Matrix CS API, media repo, and Admin UI re-homed onto the single Elixir/Bandit listener at `core:4000`)
- **Base:** `f2ed7dcd` (parent of first epic commit `aa40ff25`)
- **HEAD:** `8608e7aa`
- **Diff range:** `git diff f2ed7dcd..HEAD` (653 files, +14,764 / −130,973)
- **Stories covered:** elixir-http-foundation, oidc-middleware-migration, matrix-api-migration, media-gateway-migration, admin-ui-migration, elixir-stack-regression, go-removal-cleanup
- **Architecture note honored:** ADR-018 (no domain model, inline raw SQL). Inline SQL / SQL duplication NOT treated as findings. All inline SQL confirmed parameterized (`Ecto.Adapters.SQL.query/3` with `$1`/`$2` positional params) — no injection.

## Verdict

**CLEAN** — No CRITICAL, no HIGH.

All four HIGH/blocking findings carried into this epic from per-story reviews are **RESOLVED** and verified in the live code. Remaining items are MEDIUM/LOW advisories, several of them pre-existing-architecture limitations that are stricter than the behaviour they replaced.

**Epic security gate: PASS.**

## Findings

| # | Severity | Story | Location | Vulnerability | Status |
|---|----------|-------|----------|---------------|--------|
| F-1 | MEDIUM | media-gateway-migration | `media/membership.ex:53`, `media/db.ex` | Media download authz degrades to "member of ANY room" (no per-media room link in `media_files`) | Still-open (accepted gap; not a regression — see detail) |
| F-2 | MEDIUM | media-gateway-migration / deploy | `plugs/rate_limit.ex:131`, `docker-compose.yml` | Per-IP rate limit keys on `conn.remote_ip`; behind an ALB/nginx all clients coalesce into one bucket | Still-open (fails SAFE; deployment-config) |
| F-3 | LOW | media-gateway-migration | `core/config/runtime.exs:50,64-69` | `NEBU_MINIO_USE_SSL` defaults `false`; no production assertion that a real S3 endpoint uses `https://` | Still-open (F-3 from per-story; partially mitigated) |
| F-4 | LOW | go-removal-cleanup | `admin/auth.ex:170`, `matrix_public.ex` (503 bodies) | Config-error reason atoms reflected in 5xx response bodies | Still-open (info-disclosure of config state only) |
| F-5 | LOW/INFO | go-removal-cleanup | `admin/auth.ex:425` `admin_claim?/1` | Admin gate matches the group value across ALL ID-token claims, not a specific claim key | Carry-over (faithful Go parity; IdP-signed) |

## Resolved (previously HIGH / blocking — verified fixed at HEAD)

- **matrix-api-migration F-1 (HIGH) — logout-revocation bypass — RESOLVED.** A token denylist now exists (`token_denylist.ex`, ETS, keyed by `jti` or SHA-256 token hash, entries expire at `exp`). `OidcPlug.call/2` consults it AFTER cryptographic verification (`check_denylist/2`, oidc_plug.ex:85) and rejects revoked tokens with `401 M_UNKNOWN_TOKEN`. `POST /logout` (protected.ex:104) calls `revoke_access_token/1` which adds the presented token (stashed by OidcPlug as `:access_token` + `:oidc_claims`). The logout no-op regression is closed. (Volatile-on-restart trade-off is documented and bounded by short OIDC `exp` — acceptable for MVP; Postgres-backed denylist tracked as follow-up.)
- **matrix-api-migration F-2 / pattern #58 (MEDIUM→escalated) — `:httpc` TLS-verification gap — RESOLVED in BOTH places.** `jwks_cache.ex:173` (`http_opts_for/1`) and `oidc_metadata.ex:79` (`tls_opts_for/1`) both pass `ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get(), customize_hostname_check: pkix_verify_hostname_match_fun(:https)]` for `https://`, empty opts for `http://` (dev-internal Dex per ADR-012). The admin token exchange (`admin/auth.ex:402`) uses the same pattern. The third-strike pattern is closed; project-wide all four `:httpc`/TLS outbound paths verify peers.
- **oidc-middleware-migration M-2 (MEDIUM) — alg allowlist — RESOLVED.** `OidcPlug.@allowed_algs` is an explicit asymmetric-only allowlist (RS/ES/PS); `none` and all HMAC are rejected before key selection (`check_alg/1`). alg-confusion is now fail-closed by design, not by accident.
- **oidc-middleware-migration M-3 (MEDIUM) — fail-closed iss/aud — RESOLVED.** `check_issuer/1` and `check_audience/2` reject when issuer/audience is `nil`/`""` (`:issuer_not_configured` / `:audience_not_configured`); `runtime.exs:17-18` additionally `raise`s at boot in prod/dev if `NEBU_OIDC_ISSUER` / `NEBU_OIDC_AUDIENCE` are unset. Fail-open class eliminated.
- **admin-ui-migration F-1 (MEDIUM) — at-rest key `SHA-256("")` fallback — RESOLVED.** `bootstrap_live.ex:309 at_rest_key/0` now `raise`s when the internal secret resolves empty ("refusing to encrypt the OIDC client secret under SHA-256(\"\")") instead of silently keying with a publicly-computable hash.
- **admin-ui-migration F-2 (MEDIUM) — session cookie `secure` flag — RESOLVED.** `admin_endpoint.ex:29` sets `secure: Application.compile_env(:nebu_http, :admin_session_secure, true)` (default true → fail-closed in prod), plus `http_only: true` and `same_site: "Lax"`.

## Re-examination of items deferred to SEC Gate 2

### media-gateway-migration F-3 — https/SNI on the S3/MinIO client — STILL-OPEN (LOW)
ExAws S3 scheme is driven by `NEBU_MINIO_USE_SSL` (default `false` → `http://`), set in `runtime.exs:64-69`. For the internal Docker MinIO this is acceptable (ADR-012). The residual gap is the same as the Stackit-objectstore MEMORY pattern: there is no production-time assertion that a *real* S3 endpoint is reached over `https://`, and `USE_SSL` is independently flippable. hackney (the ExAws transport) does verify peer certs by default when scheme is https, so SNI/cert validation itself is sound once `USE_SSL=true`. Classify **LOW** (no exploit path in the shipped Compose topology; hardening = fence `USE_SSL=true` as a non-overridable production constant + reject `http://` for non-internal S3 endpoints).

### media-gateway-migration F-5 — member-of-any-room authorization — STILL-OPEN (MEDIUM, accepted gap, NOT a regression)
`media_files` has no `room_id` column (pre-existing schema, unchanged by this epic — migrations are byte-identical to the Go originals, see below). `Media.with_authorised_media/4` looks the row up, gets `room_id: nil`, and `Membership.member?(nil, user)` degrades to "is the user a member of ANY room" (`@sql_member_of_any`). Net: any authenticated user who is a member of ≥1 room can download ANY media id.

**Why this is MEDIUM, not HIGH:** (1) It is NOT a regression — the Go `/_matrix/media/v3/download` handler was *intentionally unauthenticated* ("This endpoint is intentionally unauthenticated per Matrix spec", `media/internal/download/handler.go:86`). The Elixir migration ADDED OidcPlug authentication AND a (coarse) membership check, so the live posture is *strictly stronger* than what shipped before. (2) It is fail-closed (zero-room / unknown user → `403`). (3) `media_id` is 128 bits of `:crypto.strong_rand_bytes(16)` (unguessable), so the IDOR enumeration surface is bounded by an unguessable id; there is no listing endpoint. Properly documented in both `media/db.ex` and `media/membership.ex` as a tracked follow-up requiring a schema change (`media_files.room_id` or join table).

### media-gateway-migration F-6 — MinIO key escrow handling — STILL-OPEN (by design, ADR-011)
Per-object AES-256-GCM keys + nonces are stored as hex in `media_files.aes_key_hex` / `nonce_hex` (plaintext columns). This is the documented ADR-011 *managed E2EE / server-side decryption* escrow model — the server is intentionally able to decrypt media at rest. It is NOT true E2EE (per MEMORY: `project_e2ee_direction.md`). The DB column itself is not separately encrypted; confidentiality of the at-rest blob in object storage depends on (a) object-store ACLs and (b) DB access control / RLS. This is consistent with the prior Go behaviour and the explicit architecture decision — **not a finding**, recorded as accepted-by-design. (Crypto primitive itself is correct: AES-256-GCM, 32-byte random key + 12-byte random nonce per object, GCM auth-tag verified on decrypt, byte-parity with the Go gateway.)

### admin-ui-migration deferred LOW items — RESOLVED / advisory
- LOW (Plug.Parsers no `length:` cap on admin routes): the admin endpoint still uses default Plug.Parsers (`admin_endpoint.ex:49`) with no explicit `length:`. There is no body-POST admin route today (the OIDC legs are all GET; LiveView form data rides the websocket). Practical risk unchanged — **LOW advisory**, fix when the first admin POST form lands.
- LOW (`decode16 :mixed` vs Go lower hex): cosmetic, no security impact — accepts both cases, never produces ambiguous output.
- LOW/INFO (`put_current_user` cross-service bridge): now LIVE — the OIDC-exchange leg (`do_callback/3`) calls `put_current_user/2`, which is the trust-establishment point. Re-reviewed (see Admin login section) — sound.

## Cross-story / combined-surface analysis

- **Single live auth authority — VERIFIED, no bypass window.** With the Go gateway removed, `OidcPlug` is the sole Bearer authority. Route ordering in `NebuHttp.Router` is load-bearing and correct: explicit unauthenticated paths (login, GET profile, MSC2965 discovery) → `MatrixPublic` (no OidcPlug, by spec); `/_matrix/media` → `Router.Media` (OidcPlug in pipeline); catch-all `/_matrix` → `Router.Protected` (OidcPlug in pipeline); `/admin` → Phoenix `live_session on_mount {:require_admin}`. PUT-profile under the public `/profile` forward runs OidcPlug inline (`matrix_public.ex:331 authenticate/1`). The login handler and admin login reuse the EXACT same `verify_token` path — exactly one verification code path, no divergent auth.
- **gRPC port not exposed.** `docker-compose.yml:123-126` publishes only the Bandit listener (4000 → host 8008/8080/4000); gRPC 9000 is explicitly NOT published. HTTP handlers call `Nebu.EventDispatcher.Server.*` functions directly via a fake stream (`Matrix.stream/1`) injecting `x-user-id`/`x-system-role`; the identity is trusted because OidcPlug validated the Bearer first. All HTTP-originated calls hard-code `system_role: "user"`, so the HTTP surface can never reach the role-gated admin gRPC handlers (Epic 14 bulk-import etc.) with elevated role — fail-safe.
- **Migrations re-home — NO schema/RLS/policy regression.** The golang-migrate SQL was moved from `gateway/migrations/` to `core/apps/nebu_db/priv/migrations/`. All six files (000001–000003, up + down) are **byte-identical** to the `f2ed7dcd` originals (verified by `diff`). `Nebu.Release.migrate/0` reuses the exact `schema_migrations(version BIGINT PK, dirty BOOLEAN)` table and only applies versions strictly greater than the recorded one (`select_pending/2`), transaction-wrapped, raises on `dirty`. An existing Go-migrated DB (at version 3) is seen as up-to-date → **no double-apply, no skip**. The audit_log FORCE-RLS exception (MEMORY accepted risk, Story 13.14) is preserved unchanged. No new tables added this epic, so no new-table-missing-RLS exposure.
- **Token denylist + per-IP rate limit are now the live edge controls.** Both are ETS, eagerly created at boot (`application.ex:13-14`, closing the R-2 fail-open race) with a lazy fallback. Rate limiter keys on `conn.remote_ip` (NOT X-Forwarded-For) — correctly avoids the XFF-spoof bypass (MEMORY #31) in the directly-exposed Compose topology; the inverse coalescing issue behind a proxy is F-2 (fails safe).
- **No secrets in logs.** No token/secret/claims content is logged anywhere in the new code; `Logger.warning/error` calls carry only error-atom reasons. `JsonBody` enforces a 1 MB body cap; media upload caps at 50 MB with chunked read-and-bail; preview_url body is stream-capped at 1 MiB.

## Admin OIDC Authorization-Code + PKCE login — focused review (NebuHttp.Admin.Auth)

Sound on every checked dimension:
- **PKCE:** S256 only (`code_challenge_method=S256`); plain never offered; verifier = 32 random bytes → 43-char base64url (RFC 7636 §4.1).
- **state (CSRF):** `random_token(16)`, compared constant-time (`Plug.Crypto.secure_compare`), with TTL expiry (600 s); missing/forged state fails CLOSED → 400 (`validate_state/2`).
- **nonce (replay):** `random_token(32)`, echoed in ID token, compared constant-time; absent stored or token nonce fails CLOSED (`check_nonce/2`).
- **ID-token validation:** delegated verbatim to `OidcPlug.verify_token/1` with `audience:` override = admin client_id — same alg allowlist, JWKS signature, fail-closed iss, exp, sub. No alg confusion, no `alg:none`, no missing-exp acceptance.
- **Open redirect:** `redirect_uri` is a fixed server-controlled config value (`NEBU_ADMIN_OIDC_REDIRECT_URI`), explicitly NOT derived from Host/X-Forwarded-* headers (`auth.ex:380`). Post-login target is the hard-coded `/admin/rooms`. No open redirect.
- **Session fixation:** `put_current_user/2` calls `configure_session(renew: true)` on privilege elevation. Logout uses `configure_session(drop: true)`.
- **Admin-claim gate:** `check_admin/1` enforced after token verification + nonce; byte-parity with Go `MatchesAdminGroupClaim` (F-5/INFO). Session capped at `min(idToken.exp, now+8h)`, enforced in `on_mount`.
- **Cookie flags:** `secure` (default true), `http_only: true`, `same_site: "Lax"` (Lax required — callback arrives via cross-site IdP redirect). CSRF `protect_from_forgery` + CSP (`script-src 'self'`, no unsafe-eval, no deprecated plugin-types) in the `:browser` pipeline.
- **Token exchange:** HTTP Basic client auth + PKCE verifier over TLS-verified `:httpc` (https issuers). Discovery via the TLS-verifying `OidcMetadata` fetcher against the *configured* issuer (not attacker-controlled) — no SSRF.

## Accepted Risks (carried, no new sign-off required this epic)

- `audit_log` FORCE RLS removal (Story 13.14, Phil 2026-05-18) — unchanged, migrations byte-identical.
- ADR-011 managed E2EE key escrow (server-side media decryption) — F-6 above, by design.
- F-5 media member-of-any-room — documented accepted gap; recommend formal follow-up story for per-media room scoping.

## Follow-up Stories Required

None blocking (no CRITICAL/HIGH). Recommended hardening backlog (non-blocking):
1. `media-per-room-scoping` — add `media_files.room_id` (or join table) and tighten `Membership.member?` to per-media room (closes F-5 MEDIUM).
2. `rate-limit-trusted-proxy` — add a `RemoteIp`/trusted-proxy CIDR config so the per-IP limiter sees real client IPs behind ALB/nginx (closes F-2).
3. `s3-tls-production-fence` — assert `https://` + non-overridable `USE_SSL=true` for non-internal S3 endpoints (closes F-3).
4. (optional) Postgres-backed token denylist to survive node restart within the OIDC `exp` window.

## Summary

CRITICAL: 0 — HIGH: 0 — MEDIUM: 2 (F-1 media authz scope, F-2 proxy rate-limit coalescing) — LOW: 3 (F-3 S3 TLS fence, F-4 config-reason in 5xx body, admin Plug.Parsers cap) — INFO: 1 (F-5 admin-claim breadth, Go parity)

All previously-blocking HIGH/MEDIUM findings (logout revocation, :httpc TLS verification ×2, alg allowlist, fail-closed iss/aud, at-rest empty-key fallback, session secure flag) are RESOLVED and verified at HEAD. Migrations are a byte-identical re-home with no schema/RLS regression and no double-apply. The single Bandit listener has no auth-bypass window; OidcPlug is the live authority; gRPC is not externally reachable. The admin OIDC PKCE login is correctly hardened.

**Epic security gate: PASS.**
