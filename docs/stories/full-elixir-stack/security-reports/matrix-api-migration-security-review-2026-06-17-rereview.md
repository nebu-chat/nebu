# Security Re-Review — matrix-api-migration (SEC Gate 1, story-level)

**Reviewer:** Kassandra (adversarial security reviewer)
**Date:** 2026-06-17
**Epic:** full-elixir-stack
**Type:** RE-REVIEW after coordinator chose FIX NOW for the prior BLOCKED verdict.
**Prior report:** `matrix-api-migration-security-review-2026-06-17.md` (1 HIGH F-1, 2 MEDIUM F-2/F-3, 2 LOW F-4/F-5; F-2 already fixed in-cycle).
**Diff scope:** `git diff --staged -- core/` — adds `TokenDenylist`, `Plugs.RateLimit`, denylist consult + `:access_token` assign in `OidcPlug`, logout revocation in `Protected`, login/sync rate limits, `runtime.exs` raise-on-missing-OIDC, `:security_headers` before_send.

**Verdict: PASS — 0 CRITICAL, 0 HIGH.**

---

## Findings

| # | Severity | Location | Vulnerability | Remediation |
|---|----------|----------|---------------|-------------|
| R-1 | LOW | `core/apps/nebu_http/lib/nebu_http/token_denylist.ex:85-98` | **Denylist entries are only reaped lazily on a same-key lookup.** A revoked token that is never presented again is never deleted; the table grows one tiny entry per logout (`{:jti, str}`/`{:hash, 64hex}` + int exp) until the node restarts (state is volatile). For an enterprise tenant with high logout churn this is slow, bounded-by-restart memory growth, not a request-amplified DoS. Accepted-trade-off territory, but worth a periodic sweep. | Optional: a periodic `:timer`/GenServer sweep that drops entries whose `exp < now`, or migrate to the tracked Postgres-backed denylist hardening (which can `DELETE WHERE exp < now()`). Not blocking. |
| R-2 | LOW (info) | `token_denylist.ex:79`, `rate_limit.ex:110`, `oidc_plug.ex:186` | **`rescue ArgumentError -> false/:ok` is fail-OPEN.** If an `:ets` op ever raises (only realistically during the table-creation TOCTOU window), `revoked?` returns `false` (token accepted) and `take_token` returns `:ok` (request passes). The window is the few microseconds between `ensure_table`'s `whereis` and the racing `:ets.new`; after creation neither `lookup` nor `insert` raises. Blast radius is negligible and the fail-open direction is the correct availability choice for a coarse limiter — but for the denylist it technically lets a revoked token through during that window. | Optional: create both ETS tables eagerly in `NebuHttp.Application` start (parity with how supervised caches are usually owned) so the lazy-create race cannot occur and the rescue becomes truly unreachable. Not blocking. |

No CRITICAL, HIGH, or MEDIUM findings introduced by this cycle. The prior MEDIUM/HIGH items are resolved (see PASS/FAIL below).

---

## Required verification — PASS/FAIL

### 1. Does POST /logout actually revoke the presented token, and does OidcPlug reject the reused token? — **PASS**

Traced end to end:

- `OidcPlug.call/2` (`oidc_plug.ex:46-64`) on success assigns BOTH `:access_token` (the raw verified compact JWS, line 61) and `:oidc_claims` (line 63). These are only set after `verify_token` + `check_denylist` succeed, so they are present on every authenticated request and never on an unauthenticated one.
- `Protected` `POST /client/v3/logout` (`protected.ex:94-114`) calls `revoke_access_token/1` (`:116-133`), which reads `conn.assigns[:access_token]` + `conn.assigns[:oidc_claims]["exp"]` and calls `TokenDenylist.revoke(claims["jti"], token, exp)` keyed by jti-or-hash, self-expiring at `exp`.
- On the next request, `OidcPlug.call/2` runs `check_denylist/2` (`:85-87`) → `TokenDenylist.revoked?(claims["jti"], token)` → returns `{:error, :revoked}` → `deny(conn, "M_UNKNOWN_TOKEN", "Access token has been revoked")` (`:72-75`).

The full round-trip is proven by a real test, not a stub: `matrix_router_test.exs:425-446` does use(200) → logout(200) → reuse → **401 M_UNKNOWN_TOKEN**, with the denylist table cleared first so no prior test masks it. `oidc_plug_test.exs:505-548` additionally proves the consult in isolation by jti AND by hash, and `:553-566` proves the `:access_token`/`:oidc_claims` assigns exist for logout to consume.

### 2. Is the denylist consulted on EVERY authenticated request, only after crypto verification, with no bypass? — **PASS**

- **After verification:** `call/2`'s `with` runs `verify_token(token)` (signature/alg/iss/aud/exp/sub) BEFORE `check_denylist/2`. An attacker cannot pre-populate or probe the denylist by spraying unsigned strings — they never reach the consult. Confirmed.
- **Every authenticated request:** `OidcPlug` is `plug`ged in the `Protected` pipeline (`protected.ex:26`), which the top router forwards all non-public `/_matrix` traffic to (`router.ex:68`). PUT-profile under the public `/profile` subtree runs `OidcPlug` inline via `authenticate/1` (`matrix_public.ex:331-339`) and the `Protected` fallback re-runs it. No authenticated route reaches a handler without passing the consult.
- **Key-derivation symmetry (the bypass I hunted for):** `revoke` inserts ONE entry under `key(jti, token) = jti_key(jti) || hash_key(token)` — jti if the claim is a non-empty binary, else the SHA-256 hash. `revoked?` checks BOTH `jti_key(jti)` OR `hash_key(token)`. A signed JWT carries the same `jti` claim on every presentation, so a token revoked-by-jti always re-matches by jti, and a token revoked-by-hash (no jti) always re-matches by hash. There is no jti↔hash mismatch gap: the union check on the read side is a strict superset of whichever single key the write side chose. Confirmed clean.
- **Self-expiry correctness:** an entry whose `exp <= now` reads as NOT revoked and is lazily deleted (`:85-98`) — so a re-issued OIDC token that happens to collide on hash after the old one expired is never wrongly blocked. Correct direction.
- **Fail-open:** see R-2 — bounded to the table-creation race window, negligible.

### 3. Is POST /login rate-limited and does it 429? Is /sync covered? — **PASS**

- **/login:** `matrix_public.ex:64-70` runs `RateLimit.call` (30/min, burst 10 — Go `strictRL` parity) and returns the halted conn BEFORE `do_login`, so the limiter fires before the CPU-bound JWKS verification. On exhaustion → 429 `M_LIMIT_EXCEEDED` + `Retry-After`. Proven by `matrix_router_test.exs:303-330` (burst from one IP yields a 429 with the Matrix envelope + Retry-After) and `rate_limit_test.exs:32-66` (burst boundary, per-IP isolation).
- **/sync:** `protected.ex:41-51` applies a 600/min, burst 100 limiter (generous, sits behind OidcPlug) before `do_sync`.
- **IP key:** uses `conn.remote_ip` (the connected peer), NOT a client-supplied `X-Forwarded-For` — a client cannot spoof its own bucket key. Correct safe default given no trusted-proxy config.
- **Escape hatch:** `NEBU_RATE_LIMIT_DISABLED=true` / `:rate_limit_disabled` no-ops the plug (Go parity), tested at `rate_limit_test.exs:68-77`. This is a deliberate test/dev hatch; it must not be set in production — noted, not a finding (matches the Go gateway's existing env).

### 4. No auth-bypass (re-confirmed) — **PASS**

- Every protected `/_matrix` route passes through `OidcPlug` (Protected pipeline) before its handler; the only authenticated route living in the public router (PUT profile) gates on `OidcPlug.call` + `conn.halted` (`matrix_public.ex:88-98, 331-339`). Unchanged from the prior CLEAN assessment and still correct.
- `MatrixPublic` `get "/"` request_path disambiguation (`matrix_public.ex:35-54`) still only selects between `auth_issuer` / `auth_metadata` / `/login` — all unauthenticated, static, no state mutation. Reachable only after a prefix-forward already matched a public path, so it cannot be steered onto an authenticated handler. Unchanged, still clean.
- The new `:access_token` assign and the logout revoke are reachable ONLY post-OidcPlug: `revoke_access_token` reads `conn.assigns[:access_token]`, which is set exclusively inside `OidcPlug.call` after a token verifies. An unauthenticated request to `/logout` is halted by OidcPlug (Protected pipeline) before the handler runs — it can neither revoke an arbitrary token nor reach the assign. The defensive `_ -> :ok` branch (`protected.ex:124-132`) only fires if a verified token somehow lacked an integer `exp`, which `check_exp` already rejects upstream — so a missing-exp logout simply revokes nothing and returns 200, never a crash or a forged revocation. Confirmed.

### 5. New findings introduced by the changes — see R-1 (lazy-reap unbounded growth, LOW) and R-2 (fail-open ETS race, LOW info)

- **Rate-limiter fail-open:** R-2. Bounded to the table-creation race; steady-state `rate_per_min` still bounds throughput. Not exploitable as a sustained bypass.
- **Denylist memory exhaustion:** R-1. Lazy reap only; bounded by restart (volatile). LOW.
- **Timing side-channel in `revoked?`:** the lookup is on `jti` (server-trusted claim) or a SHA-256 hash key, not a secret comparison — there is no secret to leak via timing here (the token was already cryptographically verified; the denylist only answers "was this revoked"). No finding.
- **F-5 before_send coverage:** `register_before_send` is installed at the FRONT of the top-level pipeline (`router.ex:13-22, 79-83`), so it fires on every `send_resp`, including responses from the forwarded `MatrixPublic`/`Protected` sub-routers and CORSPlug's halted 204 preflight. `matrix_router_test.exs:268-279` asserts `x-content-type-options: nosniff` across response paths. No missed path found. Resolved.

---

## Prior-finding disposition (F-1 .. F-5)

- **F-1 (HIGH — logout-revocation bypass): RESOLVED.** Denylist consult after verify + populate on logout + real round-trip regression test. (Verification 1 & 2.)
- **F-2 (MEDIUM — well-known TLS): RESOLVED** (prior cycle; `OidcMetadata.do_fetch` enables `verify: :verify_peer` + CA certs + hostname match for https issuers). Unchanged this cycle.
- **F-3 (MEDIUM — login rate-limit): RESOLVED.** Per-IP token bucket on /login (30/min, burst 10) and /sync (600/min, burst 100), 429 + Retry-After, tested. (Verification 3.)
- **F-4 (LOW — raise on missing OIDC config): RESOLVED.** `runtime.exs:17-18` raises on missing `NEBU_OIDC_ISSUER`/`NEBU_OIDC_AUDIENCE` in prod/dev.
- **F-5 (LOW — nosniff header): RESOLVED.** `:security_headers` before_send sets `X-Content-Type-Options: nosniff` on all responses, tested.
- **MEDIUM-2 (alg allowlist) / MEDIUM-3 (fail-closed iss/aud) carry-overs: STILL RESOLVED** (unchanged in `oidc_plug.ex`).

---

## Accepted trade-offs (verified genuinely bounded, NOT re-raised)

- **Volatile ETS for the denylist and the rate limiter.** Confirmed bounded: on a node restart the denylist empties, so a token revoked-but-not-yet-expired could be re-accepted until its OIDC `exp` (short-lived). This is the documented single-node / rolling-restart MVP posture, mirrors the Go in-memory test double, and the production Postgres-backed denylist is a tracked follow-up. The rate limiter resetting to full on restart cannot be weaponised because steady-state `rate_per_min` re-bounds throughput within seconds. Per the review constraints I do NOT re-raise volatility as HIGH — I found no concrete exploit in the delivered single-node/rolling-restart model. The lazy-reap growth nuance is logged as R-1 (LOW), not as a volatility re-escalation.
- **ADR-018 inline SQL** in `profile/db.ex`: not a finding.

---

## Summary

- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 2 (R-1 lazy-reap growth; R-2 fail-open ETS race — both bounded, non-blocking)

All five prior findings (F-1..F-5) and both carry-over MEDIUMs are resolved and backed by genuine tests (not claims). The two new LOW items are bounded hardening notes suitable for the tracked follow-up pass.

**Verdict: PASS — 0 CRITICAL, 0 HIGH. SEC Gate 1 cleared. Commit may proceed; R-1/R-2 are non-blocking hardening notes.**
