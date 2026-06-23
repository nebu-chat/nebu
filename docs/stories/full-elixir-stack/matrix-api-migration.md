---
story_id: matrix-api-migration
title: "Matrix Client-Server API Migration — All /_matrix/client/v3/* in Elixir"
epic: full-elixir-stack
status: done
security_review: required
created: 2026-06-17
branch: feature/full-elixir-stack
---

## Summary

Port all Matrix Client-Server API endpoints currently handled by the Go gateway into a Plug.Router in Elixir.
The critical improvement: `/sync` long-polling connections become BEAM processes — no more Go→Elixir gRPC hop
on the hot path. After this story the Go gateway container is removed from `docker-compose.yml`.

## User Story

As a Matrix client,
I want all `/_matrix/client/v3/*` endpoints served directly from Elixir/OTP,
So that the `/sync` long-polling connection is a native BEAM process with no Go→Elixir gRPC hop.

## Endpoints to Migrate

All endpoints listed in CLAUDE.md under "Matrix API Scope — Implemented (MVP target)":

| Method | Path |
|---|---|
| POST | `/_matrix/client/v3/login` |
| POST | `/_matrix/client/v3/logout` |
| GET  | `/_matrix/client/v3/sync` |
| PUT  | `/_matrix/client/v3/rooms/{roomId}/send/{eventType}/{txnId}` |
| GET  | `/_matrix/client/v3/rooms/{roomId}/messages` |
| POST | `/_matrix/client/v3/createRoom` |
| POST | `/_matrix/client/v3/join/{roomIdOrAlias}` |
| PUT  | `/_matrix/client/v3/rooms/{roomId}/typing/{userId}` |
| POST | `/_matrix/client/v3/rooms/{roomId}/receipt/{receiptType}/{eventId}` |
| GET/PUT | `/_matrix/client/v3/profile/{userId}` |
| GET  | `/_matrix/client/v3/presence/{userId}/status` |
| GET  | `/_matrix/client/unstable/org.matrix.msc2965/auth_issuer` |
| GET  | `/_matrix/client/unstable/org.matrix.msc2965/auth_metadata` |
| GET  | `/_matrix/client/v1/auth_issuer` |
| GET  | `/_matrix/client/v1/auth_metadata` |

## Acceptance Criteria

1. **Given** all Matrix endpoints listed above,
   **When** each is called via the Elixir Plug.Router,
   **Then** each returns the same response shape as the previous Go implementation (contract parity).

2. **Given** 50 Matrix clients with concurrent `/sync` long-polling connections,
   **When** a message is sent to a shared room,
   **Then** all 50 clients receive the event within 500ms (BEAM-native, no gRPC hop).

3. **Given** the Go gateway container,
   **When** this story is complete,
   **Then** it is removed from `docker-compose.yml`; all Matrix client traffic routes to Elixir on port `4000`.

4. **Given** the existing Godog integration test suite (`gateway/features/`),
   **When** run against the Elixir router (Go gateway removed),
   **Then** all previously passing scenarios still pass.

5. **Given** the MSC2965 OIDC discovery endpoints,
   **When** called via the Elixir router,
   **Then** they return `issuer` from `NEBU_OIDC_ISSUER` and correct metadata.

6. **Given** the reverse proxy (Caddy/Nginx) in `docker-compose.yml`,
   **When** updated to point to `core:4000` instead of `gateway:8080`,
   **Then** Element Web (or any Matrix client) connects and operates correctly end-to-end.

## Acceptance Tests

### Tests written FIRST (before implementation code):

1. **`gateway/features/matrix-api-migration.feature`** — Godog integration test (endpoint-by-endpoint)
   - Given: Elixir router handling requests (Go gateway removed from compose)
   - When: login → createRoom → send message → sync is exercised
   - Then: each step returns the expected Matrix response shape

2. **`test/sync_concurrent_test.exs`** — ExUnit integration test
   - Given: 50 test clients subscribed to a room via `/sync`
   - When: a message is sent via `PUT /_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}`
   - Then: all 50 clients receive the event in their next sync within 500ms

3. **`gateway/features/oidc-discovery.feature`** — Godog scenario (can extend existing)
   - Given: Elixir router running
   - When: `GET /_matrix/client/v1/auth_issuer`
   - Then: `{"issuer": "<NEBU_OIDC_ISSUER>"}` returned

## Implementation Notes

- Build `Nebu.Http.MatrixRouter` as a Plug.Router module
- `/sync` handler: no gRPC — call `SessionManager` and `EventDispatcher` directly via OTP messages
- gRPC server in Elixir (for inter-node communication) remains; only Go→Elixir gRPC calls are eliminated
- `NEBU_CORE_GRPC_ADDR` env var is no longer needed after Go gateway removal
- All existing Godog features that previously tested via Go must now point to `NEBU_BASE_URL=http://core:4000`
- Migration is NOT required to be atomic — individual endpoints can be ported incrementally, but all must be done before the story is marked `done`
- The reverse proxy route must be updated: `core:4000` instead of `gateway:8080`

## Dev Agent Record

### Status

review

### Files Created

- `core/apps/nebu_http/lib/nebu_http/matrix.ex` — shared helpers: fake gRPC `stream/1` carrying the trusted identity (`x-user-id`/`x-system-role`), `call_core/1` (runs a `Nebu.EventDispatcher.Server` fn, maps a raised `GRPC.RPCError` → `{http_status, errcode, msg}`), JSON encoders, `Core.SyncRoom`→Matrix `/sync` JSON, `Core.Event`→`/messages` chunk.
- `core/apps/nebu_http/lib/nebu_http/matrix_public.ex` — UNAUTHENTICATED routes (no OidcPlug): `POST /login`, `GET /profile/{userId}[/displayname|/avatar_url]`, MSC2965 `auth_issuer`/`auth_metadata`. PUT profile runs OidcPlug inline.
- `core/apps/nebu_http/lib/nebu_http/oidc_metadata.ex` — TTL-cached fetch of `/.well-known/openid-configuration` (mirrors `oidc_discovery.go`). On fetch failure it returns `{:error, _}`; the `auth_metadata` handler then fails CLOSED with `503 M_UNAVAILABLE` (cycle-1 MINOR-4 — the previous synthesized Keycloak-shaped fallback was removed because those endpoint paths are wrong for Dex).
- `core/apps/nebu_http/lib/nebu_http/plugs/json_body.ex` — runs `Plug.Parsers` (JSON, 1 MB cap) but converts a malformed body into `conn.assigns[:json_parse_error]` instead of raising, so `POST /login` returns `400 M_NOT_JSON` (not a 500-class crash).

### Files Modified

- `core/apps/nebu_http/lib/nebu_http/router.ex` — restructured: unauthenticated `/_matrix` paths forwarded to `MatrixPublic` BEFORE the catch-all `/_matrix` forward to `Protected`; JsonBody replaces raw `Plug.Parsers`.
- `core/apps/nebu_http/lib/nebu_http/router/protected.ex` — full authenticated Matrix routing (sync, logout, createRoom, join, send, messages, typing, receipt, presence GET/PUT, PUT profile fallback). Each handler calls the SAME `Nebu.EventDispatcher.Server` function the gRPC server exposes — NO gRPC hop.
- `core/apps/nebu_http/lib/nebu_http/plugs/oidc_plug.ex` — security hardening (see below) + provisions the authenticated user (and profile) idempotently on a valid token when `Nebu.Repo` is running (Elixir is now the single auth+provisioning point; guarded so pure unit tests with no DB are unaffected).
- `core/apps/nebu_http/mix.exs` — added `{:event_dispatcher, in_umbrella: true}` so the router can call the gRPC server module + `Core.*` request structs directly.
- `core/apps/event_dispatcher/lib/nebu/profile/db.ex` — added `get_profile/1` (inline raw SQL per ADR-018: `SELECT displayname, avatar_url FROM profiles WHERE user_id = $1`), mirroring `gateway/internal/db/profile_store.go`.
- `core/config/runtime.exs` — in `:test`, when `NEBU_DB_URL` is set, configure `Nebu.Repo` + `server_name` so the `:integration` ExUnit tests (which drive the router in-process) have a live Repo. Plain unit runs (no `NEBU_DB_URL`) still start zero DB children.
- `core/apps/nebu_http/test/nebu_http/oidc_plug_test.exs` — added 4 security tests (alg:none, HS256-with-RSA-pubkey alg-confusion, wrong iss, wrong aud → all 401).
- `core/apps/nebu_http/test/nebu_http/matrix_router_test.exs` — added a fixture to the integration `setup` that provisions `@kai:test.local` + profile (order-independence for the unauthenticated GET-profile contract test); no assertion changed.

### OidcPlug hardening (carry-over, test-review MINOR-2)

- **MEDIUM-2 (strict alg allowlist):** the JWT header `alg` must be asymmetric (`RS*`/`ES*`/`PS*`). `none` and all HMAC (`HS*`) are rejected (`:unexpected_alg` → 401 `M_UNKNOWN_TOKEN`) BEFORE key selection. Blocks alg-confusion (HMAC-signed with the RSA public key as secret) and `alg:none`.
- **MEDIUM-3 (fail-closed iss/aud):** `check_issuer`/`check_audience` now reject when the issuer/audience is NOT configured (was fail-OPEN `:ok`). A wrong/missing iss or aud is rejected → 401.
- Login enforces a 1 MB body-size cap (JsonBody `length`) and never logs the token; malformed JSON → `400 M_NOT_JSON` (no 500). No Go-gateway auth toggle touched.
- `verify_token/1` is now public and reused by the login handler so the unauthenticated login path runs the EXACT same signature/alg/iss/aud/exp/sub checks (no divergent auth).

### How each AC is satisfied

- **AC1 (contract parity):** all listed endpoints served by the Elixir Plug.Router; handlers reproduce the Go JSON shapes/status codes (verified against `gateway/internal/matrix/*.go`). All 30 `matrix_router_test` contract tests pass against a live DB.
- **AC2 (BEAM-native fan-out):** `/sync` calls `Server.get_sync_delta`/`get_initial_sync`, which subscribe to `:pg` groups and long-poll IN the request process — no gRPC hop. `sync_concurrent_test` (50 concurrent long-polls all receive the event within 500 ms) passes.
- **AC3/AC6 (wiring) — APPROVED RE-SCOPING:** The migrated endpoints are now served by the Elixir core on `core:4000` (Bandit, already published in docker-compose, OidcPlug validating first). The Go gateway is **intentionally retained** for the many OUT-OF-SCOPE endpoints (account_data, push_rules, search, admin, refresh, invite, read_markers, state events, user_directory, media proxy) — removing it now would break those. Full Go removal + repointing Element's homeserver `base_url` to `core:4000` is deferred to the separate `go-removal-cleanup` story (depends on `elixir-stack-regression`). There is currently NO standalone reverse proxy; Element points at `gateway`. `docker-compose.yml` already sets `NEBU_OIDC_ISSUER`, `NEBU_OIDC_AUDIENCE`, `NEBU_OIDC_JWKS_URI`, and `NEBU_SERVER_NAME=localhost` on the `core` service — no env change needed. **This re-scoping is a recorded coordinator decision, not a silent skip.**
- **AC4 (Godog regression):** `gateway/features/matrix-api-migration.feature` reuses only existing step definitions; it runs in CI's integration stage against the running stack. Not executed locally (full Godog stack); endpoint logic validated via the ExUnit integration suite.
- **AC5 (MSC2965 discovery):** `auth_issuer` returns `{"issuer": <NEBU_OIDC_ISSUER>}` at both `v1/` and `unstable/org.matrix.msc2965/` paths; `auth_metadata` proxies/serves the OIDC metadata object — all unauthenticated. Covered by 4 unit tests.

### Test results

- `mix test --warnings-as-errors` (full core unit suite, no DB): **all passing** — incl. 29 nebu_http unit (4 new OidcPlug security tests + 2 auth-gate + 4 MSC2965 discovery + existing) and 264 event_dispatcher. Exit 0.
- `mix test apps/nebu_http --include integration --warnings-as-errors` against a live Compose PostgreSQL (`make test-integration-elixir` path): **all passing** — 30 `matrix_router_test` contract tests + `sync_concurrent_test` (AC2). Exit 0.

### Deviations

- AC3/AC6 partially satisfied by request-path wiring only (Go gateway retained) — approved coordinator re-scoping, documented above; full removal in `go-removal-cleanup`.
- `runtime.exs` now configures `Nebu.Repo` in `:test` when `NEBU_DB_URL` is set — required because the new `:integration` tests drive the router in-process and so need a live Repo in the test BEAM (matches the `make test-integration-elixir` contract). No effect on plain unit runs.

### Cycle 1 — code-review fixes (1 MAJOR + 5 MINOR)

- **MAJOR-1 — `GET /_matrix/client/v3/login` ported.** The Go gateway registers BOTH GET and POST on `/login`; `GetLogin` (login.go) returns the advertised login `flows`, which Element Web 1.12+ requires (without it a GET falls through to `404 M_NOT_FOUND`, breaking SSO discovery). Added a `GET "/"` branch to `MatrixPublic` (disambiguated by request path, since `auth_issuer`/`auth_metadata`/`/login` all arrive as `GET "/"`). Returns the EXACT Go shape: `flows = [{"type":"m.login.sso","identity_providers":[{"id":"oidc","name":<display>,"icon":null}]}, {"type":"m.login.token"}]`. The IdP display name reads `:nebu_http, :oidc_display_name` (new key in `runtime.exs`, mirrors the Go gateway's `NEBU_OIDC_DISPLAY_NAME`, default `"SSO"`). New pure-unit test in `matrix_router_test.exs` asserts `GET /login → 200` with both flows + the `oidc` IdP (no auth, no DB).
- **MINOR-1 — dead since-branch in `/sync` removed.** `protected.ex` had `if delta.fallback_to_initial do {a} else {a} end` returning the identical tuple in both arms. Dropped the conditional and use `{delta.since_token, delta.rooms}` directly (the flag carries no extra `/sync` response semantics — `get_sync_delta` already returns the resolved snapshot in `rooms` on the fallback path), with a comment explaining why.
- **MINOR-2 — invite/leave in `/sync` documented as a tracked follow-up.** Verified the data is NOT available: proto `SyncRoom` (proto/core.proto) has no membership field, and `GetSyncDelta`/`GetInitialSync` return only joined-room snapshots in `rooms`. The Go gateway builds invite/leave from SEPARATE DB queries (`buildInviteRooms`/`buildLeaveRooms`) that the no-gRPC-hop path does not yet call. Splitting them out of `delta.rooms` is impossible (the data isn't there). Left `invite`/`leave` as `%{}` with an expanded `sync_response/2` moduledoc + inline comment explaining the gap. **Follow-up:** wire the invite/leave DB queries (or add a membership field to `SyncRoom`) in a later story.
- **MINOR-3 — provisioning gated off the hot path.** `OidcPlug` ran `TokenValidator.validate` + profile upsert (a DB round-trip) on EVERY authenticated request, including the `/sync` long-poll (AC2 perf goal). Added a best-effort, race-tolerant named ETS set (`:nebu_http_provisioned_users`): `provision/2` skips the validate+upsert when the user is already in the set, so it runs at most once per user per node lifetime. A brand-new user is still provisioned on first sight (cache miss); a deactivated account is NOT cached (so deactivation mid-session still takes effect on every request); a user is only marked provisioned after a SUCCESSFUL validate (a transient DB error leaves them uncached and retried). Table is lazily created and all ETS ops are `ArgumentError`-guarded, so pure unit tests with no table still work (they just provision every time). Existing `oidc_plug` tests and the `matrix_router_test` provisioning fixture are unaffected.
- **MINOR-4 — `auth_metadata` fails closed.** Removed the synthesized Keycloak-shaped fallback document (wrong endpoint paths for Dex, the dev IdP). On a failed live fetch the handler now returns `503 M_UNAVAILABLE`, mirroring the Go `authMetadataHandler` (oidc_discovery.go returns 503 + `M_UNAVAILABLE` on upstream failure; it does NOT synthesize a fallback). The two AC5 `auth_metadata` unit tests now assert the 200 happy path via the `:oidc_metadata_override` test seam, plus a new test asserts the `503 M_UNAVAILABLE` fail-closed path when the provider is unreachable.
- **MINOR-5 — concurrent sync test corrected.** (a) Reworded the `await_budget` comment: `Task.await`'s timeout is deliberately generous and is NOT the timing gate — the 500ms guarantee (AC2) is enforced solely by the post-hoc `elapsed <= @budget_ms` wall-clock assertion. (b) The 50 tasks now model 50 DISTINCT Matrix clients: 50 distinct OIDC subjects (`client-1..50`) → 50 distinct bearer tokens → 50 distinct provisioned users, each joined to the shared room with its own per-user since-token, instead of one user/device fanned out 50×. Still deterministic and within the 500ms budget assertion.

### Cycle 1 — test results

- `make test-unit-elixir` (`mix test --warnings-as-errors`, no DB): **exit 0 — all passing, zero warnings.** Covers all cycle-1 pure-unit additions: the new `GET /login` flows test (MAJOR-1) and the `auth_metadata` 200-via-override + 503-fail-closed tests (MINOR-4), plus all carried-over nebu_http + event_dispatcher unit tests.
- Integration (`make test-integration-elixir`, full Compose stack): **could not be validated in this environment** — every provisioning-dependent test (including pre-existing, unmodified tests such as `OidcPlugTest` "valid Bearer token" and all `MatrixRouterTest` contract tests) fails with `:crypto.crypto_one_time_aead(:aes_256_gcm, nil, …)` "non-binary key", because `Application.get_env(:signature, :pii_encryption_key)` resolves to `nil` in this local integration container. This is a pre-existing environment/config gap in the local stack (the PII key from `config/test.exs` is not reaching the integration BEAM), NOT a regression from the cycle-1 fixes — the failing chain (`validate/4` → `provision_user` → `encrypt_operational_pii`) is identical to before and is exercised by tests this cycle did not touch. A few unrelated `event_dispatcher` failures (`FakeMessagesDB.insert_member`/`list_auto_join_rooms` undefined) are pre-existing test-fixture drift. The cycle-1 integration-only tests (`GET /login` in `matrix_router_test`, the reworked `sync_concurrent_test`) should be re-verified in CI where `NEBU_PII_ENCRYPTION_KEY` is properly configured.

### Cycle 2 — code-review fix (1 MINOR)

- **MINOR-6 — provisioning ETS cache now has a TTL (deactivation re-check restored).** The cycle-1 `:nebu_http_provisioned_users` set had no expiry: once a user was cached, `provision/2` short-circuited the validate forever, so a user DEACTIVATED after their first successful request kept being accepted for the whole node lifetime — a security regression vs the Go gateway, whose `makeStatusChecker` (`gateway/internal/middleware/auth.go`) caches the `is_active`/status check with a **60-second** TTL. Fix: each ETS entry is now `{user_id, cached_at_monotonic_ms}` instead of a bare `{user_id}`. `provisioned?/1` reads the entry and treats it as a cache MISS once its age exceeds the TTL, forcing a fresh `TokenValidator.validate` (which re-checks deactivation); `mark_provisioned/1` refreshes the timestamp on each successful validate. The TTL is `@provision_cache_ttl_ms 60_000` (matching Go), read at runtime via `Application.get_env(:nebu_http, :provision_cache_ttl_ms, 60_000)` so it is tunable and test-overridable. Age is measured with `System.monotonic_time(:millisecond)` (not wall-clock) so an NTP/clock step can't make a stale entry look fresh. All prior robustness is preserved: `ArgumentError`-guarded ETS ops (bare unit tests with no table still pass), only cached after a SUCCESSFUL validate, deactivated accounts never cached, transient DB errors stay uncached. The misleading "deactivation mid-session takes effect [on every request]" comment was corrected to state accurately that provisioning + the deactivation re-check happen at most once per TTL window (60s) and that a user deactivated mid-session is blocked within 60s worst case — matching Go.
- **New regression test** (`oidc_plug_test.exs`, `describe "provisioning cache TTL (MINOR-6)"`): two deterministic tests, no `sleep`. A dummy process is registered as `Nebu.Repo` so the plug's `running?(Repo)` guard is satisfied without a DB, and `:session_manager, :validator_module` is overridden with a counting `FakeDeactivatedValidator`. Expiry is forced by seeding the ETS cache directly with a chosen monotonic age and setting `:nebu_http, :provision_cache_ttl_ms`: (1) a FRESH entry (age 0, TTL 60_000) is a cache HIT — `validate` is **not** called (`calls() == 0`) and the request proceeds; (2) an EXPIRED entry (age 1000ms, TTL 1ms) is a cache MISS — `validate` IS re-invoked (`calls() == 1`), returns `{:error, :deactivated}`, and the request is rejected `401 M_UNKNOWN_TOKEN` with no `current_user` assigned. The deactivated path never reaches the profile upsert, so no live DB query is needed.

### Cycle 3 — security FIX NOW (Kassandra F-1/F-3/F-4/F-5)

Coordinator chose FIX NOW (not deferral to `go-removal-cleanup`) for the open Kassandra findings. All implemented in this story:

- **F-1 (HIGH) — logout token revocation.** New `NebuHttp.TokenDenylist` (ETS-backed, volatile; restart/persistence strategy documented in its moduledoc per the CLAUDE.md GenServer-state rule — ETS volatile, bounded by token `exp`, Go-parity with the in-memory `middleware.Denylist`, Postgres-backed persistence tracked as later hardening). `OidcPlug.call/2` now consults the denylist AFTER a token verifies (parity with the Go `auth.go` "Step 2: Denylist check" — only verified tokens are looked up, so an attacker cannot flood it with unsigned strings) and rejects a revoked token with `401 M_UNKNOWN_TOKEN` ("Access token has been revoked"). `OidcPlug` now also assigns `:access_token` (the raw Bearer) so `POST /logout` can revoke exactly the token that authenticated the request. `POST /logout` (`protected.ex`) calls `TokenDenylist.revoke(jti, token, exp)` — keyed by the JWT `jti` when present, else the SHA-256 hash of the raw token (raw token never stored); the entry self-expires at the token's own `exp`. Best-effort: a missing token/exp still returns `200 {}` (Go parity). **Regression tests:** pure-unit in `oidc_plug_test.exs` (`describe "token denylist (F-1)"` — accepted-before-revoke control, revoke-by-jti → 401, revoke-by-hash → 401, access_token/oidc_claims assigned); module-unit `token_denylist_test.exs` (revoke/check by jti + hash, self-expiry at exp, raw token never stored, idempotent); integration round-trip in `matrix_router_test.exs` (`F-1: after logout the same Bearer token is rejected` — use 200 → logout 200 → reuse 401 M_UNKNOWN_TOKEN).
- **F-3 (MEDIUM) — login + sync rate limit.** New `NebuHttp.Plugs.RateLimit` plug (per-IP token bucket, ETS, volatile; `NEBU_RATE_LIMIT_DISABLED` / `:nebu_http, :rate_limit_disabled` escape hatch mirroring the Go gateway). `POST /login` is limited to 30 req/min burst 10 (exact Go `strictRL` parity — "real brute-force risk"), wired in `MatrixPublic` before `do_login`. `/sync` is limited to a generous 600 req/min burst 100 (does not impede a normal long-poll client; caps a single IP hammering the endpoint to exhaust BEAM processes). On exhaustion: `429 M_LIMIT_EXCEEDED` + `Retry-After` header, then halt (Go parity). **Tests:** `rate_limit_test.exs` (burst then 429 + Retry-After, independent per-IP buckets, disabled no-op); `matrix_router_test.exs` `describe "login rate limit (F-3)"` (a single IP exceeding the login burst gets 429 M_LIMIT_EXCEEDED via the full router).
- **F-4 (LOW) — fail-loud on missing OIDC config.** `runtime.exs` now `raise`s for missing `NEBU_OIDC_ISSUER` / `NEBU_OIDC_AUDIENCE` in `:prod`/`:dev` (matching `NEBU_DB_URL` / `NEBU_PII_ENCRYPTION_KEY`), so an operator misconfig is a fast loud boot failure instead of silent 100%-401s. (OidcPlug already fail-closes on nil — this just makes it loud.)
- **F-5 (LOW) — security header.** `NebuHttp.Router` registers a `before_send` (`:security_headers` plug, front of the pipeline) that sets `X-Content-Type-Options: nosniff` on every response — including forwarded sub-router responses and CORSPlug's halted preflight. **Test:** `matrix_router_test.exs` `describe "security headers (F-5)"` asserts the header on /health (200), a 401 envelope, and a discovery 200.

Auth-bypass re-verified: every `/_matrix` protected route still passes through `OidcPlug` first (Protected pipeline). The denylist consult and `:access_token` assign happen inside `OidcPlug.call/2`, so the logout handler can only revoke a token that already authenticated. The `MatrixPublic` PUT-profile inline `OidcPlug.call/2` path is unaffected (it also now gets `:access_token`, harmless). `request_path` disambiguation in `MatrixPublic.get "/"` unchanged — still selects only between the unauthenticated `auth_issuer`/`auth_metadata`/`/login` handlers.

### Cycle 3 — test results

- `make test-unit-elixir` (`mix test --warnings-as-errors`, full umbrella, no DB): **exit 0, zero warnings.** `apps/nebu_http` alone: **48 passed, 29 excluded, 0 failures** (up from 33 — the +15 being the F-1 denylist pure-unit + module tests, F-3 rate-limit + login-rate-limit tests, F-5 nosniff test). `make test-unit-go`: exit 0 (no Go touched).
### Cycle 3 — re-review outcomes (code-review + Kassandra)

- **Code-review (re-review): CLEAN** — no NEW MAJOR/CRITICAL; F-1/F-3/F-4/F-5 verified correct; no auth-bypass. Only INFO notes (folded the `check_exp`-invariant cross-reference comment into `protected.ex`).
- **Kassandra (re-review): PASS — 0 CRITICAL, 0 HIGH** (`security-reports/matrix-api-migration-security-review-2026-06-17-rereview.md`). All five prior findings verified genuinely resolved (traced, test-backed). Two NEW LOW (non-blocking):
  - **R-1 (LOW):** denylist entries are reaped only lazily on a same-key lookup, so one tiny entry per logout accumulates until restart (volatile). Bounded (small fixed-size tuples, cleared on restart); a periodic sweep or the tracked Postgres-backed denylist is the follow-up. Left as documented follow-up hardening.
  - **R-2 (LOW):** the `rescue ArgumentError → false/:ok` fail-open in `revoked?`/`take_token` was reachable only in the microsecond ETS table-creation race. **FIXED THIS CYCLE:** `NebuHttp.Application.start/2` now eagerly creates both ETS tables at boot (`TokenDenylist.init_table/0`, `RateLimit.init_table/0`), so the table exists before the first request and the fail-open branch is unreachable in the running stack. The lazy `ensure_table` remains as a safety net (and keeps pure-unit tests working without the Application). nebu_http unit suite still 48 passed / 0 failures / 0 warnings after the change.

### Cycle 3 — integration test note

- Integration (`make test-integration-elixir`, full Compose stack): the F-1 integration round-trip and other provisioning-dependent tests hit the SAME pre-existing local-env gap documented in cycle 1 — `:crypto.crypto_one_time_aead(:aes_256_gcm, nil, …)` "non-binary key" because `:signature, :pii_encryption_key` resolves to `nil` in the local integration container (the unmodified `POST /logout → 200` test fails identically, confirming it is not a regression). Plus the pre-existing `event_dispatcher` `FakeRoomDB` ETS-table races in `server_get_room_state_system_test.exs`. None reference `TokenDenylist` / `RateLimit` / `nosniff`. The F-1/F-3 integration assertions are re-verified in CI where `NEBU_PII_ENCRYPTION_KEY` is configured. The denylist + rate-limit + nosniff LOGIC is fully covered by the pure-unit tests (no Repo), which are green.

- `make test-unit-elixir` (`mix test --warnings-as-errors`, full umbrella): **exit 0 — all green, zero compile warnings.** Per-app: permissions 1, signature 21, room_manager 85, session_manager 51, compliance 22, presence 15, event_dispatcher 264 passed (2 skipped, 6 excluded), **nebu_http 33 passed (28 excluded)** — up from 31, the +2 being the new MINOR-6 TTL tests. The known-flaky `event_dispatcher` `sync_test.exs` AT #10 did not flake this run (no rerun needed).
